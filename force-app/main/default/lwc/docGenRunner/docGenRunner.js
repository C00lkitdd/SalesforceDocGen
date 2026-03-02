import { LightningElement, api, wire, track } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getTemplatesForObject from '@salesforce/apex/DocGenController.getTemplatesForObject';
import generateDocumentData from '@salesforce/apex/DocGenController.generateDocumentData';
import saveGeneratedDocument from '@salesforce/apex/DocGenController.saveGeneratedDocument';
import PIZZIP_JS from '@salesforce/resourceUrl/pizzip';
import DOCXTEMPLATER_JS from '@salesforce/resourceUrl/docxtemplater';
import FILESAVER_JS from '@salesforce/resourceUrl/filesaver';

export default class DocGenRunner extends LightningElement {
    @api recordId;
    @api objectApiName;
    
    @track templateOptions = [];
    @track selectedTemplateId;
    @track outputMode = 'download';
    @track templateOutputFormat = 'Document'; 
    
    isLoading = false;
    error;
    librariesLoaded = false;
    _librariesPromise;
    _templateData = []; // Store raw template metadata

    get engineUrl() {
        return '/apex/DocGenPDFEngine';
    }

    get outputOptions() {
        const formatLabel = this.templateOutputFormat || 'Document';
        return [
            { label: `Download ${formatLabel}`, value: 'download' },
            { label: `Save to Record (${formatLabel})`, value: 'save' }
        ];
    }

    @wire(getTemplatesForObject, { objectApiName: '$objectApiName' })
    wiredTemplates({ error, data }) {
        if (data) {
            this._templateData = data;
            this.templateOptions = data.map(t => ({ label: t.Name, value: t.Id }));
            this.error = undefined;
        } else if (error) {
            this.error = 'Error fetching templates: ' + (error.body ? error.body.message : error.message);
            this.templateOptions = [];
        }
    }

    renderedCallback() {
        if (this.librariesLoaded) return;
        this.librariesLoaded = true;

        const loadPizZip = loadScript(this, PIZZIP_JS)
            .catch(e => { console.error('Failed to load PizZip', e); throw e; });
            
        const loadDocxtemplater = loadScript(this, DOCXTEMPLATER_JS)
            .catch(e => { console.error('Failed to load Docxtemplater', e); throw e; });
            
        const loadFileSaver = loadScript(this, FILESAVER_JS);

        this._librariesPromise = Promise.all([
            loadPizZip,
            loadDocxtemplater,
            loadFileSaver
        ])
        .then(() => {
             console.log('Document Generation libraries loaded successfully');
        })
        .catch(error => {
            console.error('Library load error:', error);
        });
    }

    handleTemplateChange(event) {
        this.selectedTemplateId = event.detail.value;
        this.error = null;
        
        // Update the UI labels immediately based on selected template
        const selected = this._templateData.find(t => t.Id === this.selectedTemplateId);
        if (selected) {
            this.templateOutputFormat = selected.Output_Format__c || 'Document';
        }
    }

    handleOutputModeChange(event) {
        this.outputMode = event.detail.value;
    }

    get isGenerateDisabled() {
        return !this.selectedTemplateId || this.isLoading;
    }

    async generateDocument() {
        this.isLoading = true;
        this.error = null;
        
        try {
            console.log('DocGen: Starting generation process...');
            
            // 0. Ensure Libraries are loaded
            if (this._librariesPromise) {
                await this._librariesPromise;
            } else {
                 throw new Error('Libraries failed to initialize.');
            }

            if (!window.PizZip || !window.docxtemplater) {
                throw new Error('Required libraries (PizZip/docxtemplater) not found in window scope.');
            }

            // 1. Get Data and Template Content
            console.log('DocGen: Fetching template and record data...');
            const result = await generateDocumentData({ 
                templateId: this.selectedTemplateId, 
                recordId: this.recordId 
            });
            
            if (!result || !result.templateFile) {
                throw new Error('Template file content is empty or could not be retrieved.');
            }

            const templateData = result.templateFile; 
            const templateType = result.templateType;
            this.templateOutputFormat = result.outputFormat || 'Document';

            // 2. Local DOCX Generation (PizZip + docxtemplater)
            console.log('DocGen: Processing record data and initializing docxtemplater...');
            let recordData = this.flattenData(JSON.parse(JSON.stringify(result.data)));
            
            const binaryString = atob(templateData);
            const len = binaryString.length;
            const bytes = new Uint8Array(len);
            for (let i = 0; i < len; i++) {
                bytes[i] = binaryString.charCodeAt(i);
            }
            
            const zip = new window.PizZip(bytes.buffer);
            let _imageTagCounter = 0;
            const _pendingImageData = {};

            const doc = new window.docxtemplater(zip, {
                paragraphLoop: true,
                linebreaks: true,
                delimiters: {start: '{', end: '}'},
                nullGetter: () => { return ""; },
                parser: (tag) => {
                    return {
                        get: (scope) => {
                            if (tag === '.') return scope;
                            // Image tags: resolve from current scope and generate unique placeholder
                            if (tag.startsWith('%')) {
                                const fieldName = tag.substring(1);
                                const keys = fieldName.split('.');
                                let val = scope;
                                for (const key of keys) {
                                    if (val === undefined || val === null) return '';
                                    val = val[key];
                                }
                                if (val) {
                                    _imageTagCounter++;
                                    const placeholder = 'DOCGENIMG' + _imageTagCounter;
                                    _pendingImageData[placeholder] = String(val);
                                    console.log('DocGen: Image tag {%' + fieldName + '} resolved → placeholder ' + placeholder + ', value length: ' + String(val).length + ', hasDataUri: ' + String(val).includes('data:image'));
                                    return '{%' + placeholder + '}';
                                }
                                console.log('DocGen: Image tag {%' + fieldName + '} resolved to empty/null');
                                return '';
                            }
                            const keys = tag.split('.');
                            let value = scope;
                            for (let i = 0; i < keys.length; i++) {
                                if (value === undefined || value === null) return '';
                                value = value[keys[i]];
                            }
                            // Strip HTML from rich text values for regular text tags
                            if (typeof value === 'string' && value.includes('<') && (value.includes('<p') || value.includes('<div') || value.includes('<span') || value.includes('<br'))) {
                                const tmp = document.createElement('div');
                                tmp.innerHTML = value;
                                value = tmp.textContent || tmp.innerText || '';
                            }
                            return value;
                        }
                    };
                }
            });

            console.log('DocGen: Rendering template...');
            doc.render(recordData);

            // Post-process: inject images using the unique placeholder data
            console.log('DocGen: Post-processing images...');
            this.injectImages(doc.getZip(), _pendingImageData);

            const baseName = recordData.Name || recordData.QuoteNumber || recordData.CaseNumber || recordData.Subject || 'Document';
            const isPPT = templateType === 'PowerPoint';
            const isPDF = this.templateOutputFormat === 'PDF' && !isPPT;

            if (isPPT) {
                console.log('DocGen: PowerPoint detected. Generating PPTX...');
                const outBlob = doc.getZip().generate({ type: 'blob' });
                if (this.outputMode === 'save') {
                    await this.saveToSalesforce(baseName, outBlob, 'pptx');
                } else {
                    window.saveAs(outBlob, baseName + '.pptx');
                    this.showToast('Success', 'PowerPoint downloaded.', 'success');
                    this.isLoading = false;
                }
            } else if (!isPDF) {
                console.log('DocGen: Native format detected. Generating DOCX...');
                const outBlob = doc.getZip().generate({ type: 'blob' });
                if (this.outputMode === 'save') {
                    await this.saveToSalesforce(baseName, outBlob, 'docx');
                } else {
                    window.saveAs(outBlob, baseName + '.docx');
                    this.showToast('Success', 'Word document downloaded.', 'success');
                    this.isLoading = false;
                }
            } else {
                // Word DOCX -> Send to PDF Engine (For PDF Output)
                console.log('DocGen: PDF output requested. Sending to PDF Engine...');
                this.showToast('Info', 'Generating PDF...', 'info');
                const docxBuffer = doc.getZip().generate({ type: 'arraybuffer' });
                const iframe = this.template.querySelector('iframe');
                
                if (!iframe) throw new Error('PDF Engine iframe not found.');

                iframe.contentWindow.postMessage({
                    type: 'generate',
                    blob: docxBuffer,
                    fileName: baseName,
                    mode: this.outputMode 
                }, '*');
            }

        } catch (e) {
            console.error('DocGen Error Detailed:', e);
            let msg = 'Unknown error during generation';
            
            if (e.message) {
                msg = e.message;
            } else if (typeof e === 'string') {
                msg = e;
            } else {
                try {
                    msg = JSON.stringify(e);
                } catch (jsonErr) {
                    msg = 'Critical failure (could not stringify error)';
                }
            }

            if (e.properties && e.properties.errors instanceof Array) {
                msg += ': ' + e.properties.errors.map(err => err.properties.explanation).join(', ');
            }
            this.error = 'Generation Error: ' + msg;
            this.isLoading = false;
        }
    }

    connectedCallback() {
        window.addEventListener('message', this.handleMessage);
    }
    
    disconnectedCallback() {
        window.removeEventListener('message', this.handleMessage);
    }
    
    handleMessage = async (event) => {
        if (event.data.type === 'docgen_success') {
            console.log('DocGen: PDF Engine success received.');
            if (this.outputMode === 'save' && event.data.blob) {
                await this.saveToSalesforce(event.data.fileName, event.data.blob, 'pdf');
            } else {
                this.showToast('Success', 'Document Generated successfully.', 'success');
                this.isLoading = false;
            }
        } else if (event.data.type === 'docgen_error') {
            console.error('DocGen: PDF Engine reported error:', event.data.message);
            this.error = 'PDF Engine Error: ' + event.data.message;
            this.isLoading = false;
        }
    }

    async saveToSalesforce(fileName, blob, extension) {
        try {
            console.log(`DocGen: Saving ${extension} to record...`);
            this.showToast('Info', 'Saving to Record...', 'info');
            
            const base64 = await this.blobToBase64(blob);
            if (!base64) throw new Error('Failed to convert file to binary data.');

            await saveGeneratedDocument({
                recordId: this.recordId,
                fileName: fileName,
                base64Data: base64,
                extension: extension
            });
            this.showToast('Success', `${extension.toUpperCase()} saved to record.`, 'success');
        } catch (e) {
            console.error('DocGen: Save error:', e);
            this.error = 'Save Error: ' + (e.body ? e.body.message : (e.message || e));
            this.showToast('Error', 'Save failed. Check error message.', 'error');
        } finally {
            this.isLoading = false;
        }
    }

    blobToBase64(blob) {
        return new Promise((resolve, reject) => {
            if (!blob) {
                reject(new Error('Input blob is null or undefined.'));
                return;
            }
            const reader = new FileReader();
            reader.onloadend = () => {
                const base64String = reader.result.split(',')[1];
                resolve(base64String);
            };
            reader.onerror = (e) => {
                console.error('FileReader error:', e);
                reject(new Error('Error reading file data.'));
            };

            if (blob instanceof ArrayBuffer) {
                reader.readAsDataURL(new Blob([blob]));
            } else if (blob instanceof Blob) {
                reader.readAsDataURL(blob);
            } else {
                // Try treating it as a buffer if it's an TypedArray
                try {
                    reader.readAsDataURL(new Blob([blob]));
                } catch (err) {
                    reject(new Error('Input is not a valid Blob or ArrayBuffer.'));
                }
            }
        });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    /**
     * Post-processes a PizZip instance to replace {%PlaceholderKey} tags with actual images.
     * Uses imageDataMap (keyed by unique placeholder) to resolve image data per instance.
     */
    injectImages(zip, imageDataMap) {
        console.log('DocGen: injectImages called with', Object.keys(imageDataMap).length, 'pending images:', Object.keys(imageDataMap));
        const imageRegex = /\{%([^}]+)\}/g;
        let imageCount = 0;
        const images = []; // {relId, fileName, data (Uint8Array)}

        // Helper to extract base64 image from HTML <img> tag or data URI string
        const extractImage = (strVal) => {
            // HTML with <img> tag containing data URI
            if (strVal.includes('<img')) {
                const match = strVal.match(/<img[^>]+src\s*=\s*["']([^"']+)["']/i);
                if (match) {
                    const src = match[1];
                    if (src.startsWith('data:image/')) {
                        const base64Part = src.split(',')[1];
                        if (base64Part) {
                            const bin = atob(base64Part);
                            const arr = new Uint8Array(bin.length);
                            for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
                            return { data: arr, ext: src.includes('jpeg') || src.includes('jpg') ? 'jpeg' : 'png' };
                        }
                    }
                }
                return null;
            }
            // Direct base64 data URI
            if (strVal.startsWith('data:image/')) {
                const base64Part = strVal.split(',')[1];
                if (base64Part) {
                    const bin = atob(base64Part);
                    const arr = new Uint8Array(bin.length);
                    for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
                    return { data: arr, ext: strVal.includes('jpeg') || strVal.includes('jpg') ? 'jpeg' : 'png' };
                }
            }
            return null;
        };

        // Scan all XML files in the ZIP for {%...} patterns
        const xmlFiles = ['word/document.xml'];
        for (const fname of Object.keys(zip.files)) {
            if ((fname.startsWith('word/header') || fname.startsWith('word/footer')) && fname.endsWith('.xml')) {
                xmlFiles.push(fname);
            }
        }

        for (const xmlFile of xmlFiles) {
            if (!zip.files[xmlFile]) continue;
            let xml = zip.file(xmlFile).asText();
            let hasChanges = false;

            xml = xml.replace(imageRegex, (fullMatch, placeholderKey) => {
                hasChanges = true; // Always mark changes when regex matches

                const val = imageDataMap[placeholderKey];
                if (!val) {
                    console.log('DocGen: injectImages - no value for placeholder:', placeholderKey);
                    return '';
                }

                const imgResult = extractImage(val);
                if (!imgResult) {
                    console.log('DocGen: injectImages - extractImage returned null for placeholder:', placeholderKey, 'value starts with:', val.substring(0, 100));
                    return '';
                }

                imageCount++;
                const relId = 'rIdImg' + imageCount;
                const fileName = 'docgen_image_' + imageCount + '.' + imgResult.ext;
                images.push({ relId, fileName, data: imgResult.data });

                const cx = 3657600; // 4 inches in EMU
                const cy = 2743200; // 3 inches in EMU

                return '</w:t></w:r>' +
                    '<w:r><w:drawing>' +
                      '<wp:inline distT="0" distB="0" distL="0" distR="0">' +
                        '<wp:extent cx="' + cx + '" cy="' + cy + '"/>' +
                        '<wp:effectExtent l="0" t="0" r="0" b="0"/>' +
                        '<wp:docPr id="' + (900 + imageCount) + '" name="DocGenImage' + imageCount + '"/>' +
                        '<wp:cNvGraphicFramePr><a:graphicFrameLocks xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" noChangeAspect="1"/></wp:cNvGraphicFramePr>' +
                        '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                          '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                            '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                              '<pic:nvPicPr><pic:cNvPr id="0" name="DocGenImage' + imageCount + '"/><pic:cNvPicPr/></pic:nvPicPr>' +
                              '<pic:blipFill>' +
                                '<a:blip r:embed="' + relId + '"/>' +
                                '<a:stretch><a:fillRect/></a:stretch>' +
                              '</pic:blipFill>' +
                              '<pic:spPr>' +
                                '<a:xfrm><a:off x="0" y="0"/><a:ext cx="' + cx + '" cy="' + cy + '"/></a:xfrm>' +
                                '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>' +
                              '</pic:spPr>' +
                            '</pic:pic>' +
                          '</a:graphicData>' +
                        '</a:graphic>' +
                      '</wp:inline>' +
                    '</w:drawing></w:r><w:r><w:t xml:space="preserve">';
            });

            if (hasChanges) {
                zip.file(xmlFile, xml);
            }
        }

        // Update Content_Types.xml and rels
        if (images.length > 0) {
            if (zip.files['[Content_Types].xml']) {
                let ct = zip.file('[Content_Types].xml').asText();
                if (!ct.includes('Extension="png"')) {
                    ct = ct.replace('</Types>', '<Default Extension="png" ContentType="image/png"/></Types>');
                }
                if (!ct.includes('Extension="jpeg"')) {
                    ct = ct.replace('</Types>', '<Default Extension="jpeg" ContentType="image/jpeg"/></Types>');
                }
                zip.file('[Content_Types].xml', ct);
            }

            if (zip.files['word/_rels/document.xml.rels']) {
                let rels = zip.file('word/_rels/document.xml.rels').asText();
                for (const img of images) {
                    const newRel = '<Relationship Id="' + img.relId + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/' + img.fileName + '"/>';
                    rels = rels.replace('</Relationships>', newRel + '</Relationships>');
                }
                zip.file('word/_rels/document.xml.rels', rels);
            }

            for (const img of images) {
                zip.file('word/media/' + img.fileName, img.data);
            }

            console.log('DocGen: Injected ' + images.length + ' image(s) into document.');
        }
    }

    flattenData(obj) {
        if (!obj || typeof obj !== 'object') return obj;
        if (Array.isArray(obj)) return obj.map(item => this.flattenData(item));
        if (obj.hasOwnProperty('totalSize') && obj.hasOwnProperty('records')) return this.flattenData(obj.records);
        
        const newObj = {};
        for (const key in obj) {
            if (Object.prototype.hasOwnProperty.call(obj, key)) {
                if (key === 'attributes') continue; 
                newObj[key] = this.flattenData(obj[key]);
            }
        }
        return newObj;
    }
}