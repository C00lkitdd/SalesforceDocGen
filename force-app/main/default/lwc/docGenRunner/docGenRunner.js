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
    
    isLoading = false;
    error;
    librariesLoaded = false;
    _librariesPromise;

    get engineUrl() {
        return '/apex/DocGenPDFEngine';
    }

    get outputOptions() {
        return [
            { label: 'Download PDF', value: 'download' },
            { label: 'Save to Record', value: 'save' }
        ];
    }

    @wire(getTemplatesForObject, { objectApiName: '$objectApiName' })
    wiredTemplates({ error, data }) {
        if (data) {
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
            const result = await generateDocumentData({ 
                templateId: this.selectedTemplateId, 
                recordId: this.recordId 
            });
            
            const templateData = result.templateFile; 
            const templateType = result.templateType;

            // 2. Local DOCX Generation (PizZip + docxtemplater)
            let recordData = this.flattenData(JSON.parse(JSON.stringify(result.data)));
            
            const binaryString = atob(templateData);
            const len = binaryString.length;
            const bytes = new Uint8Array(len);
            for (let i = 0; i < len; i++) {
                bytes[i] = binaryString.charCodeAt(i);
            }
            
            const zip = new window.PizZip(bytes.buffer);
            const doc = new window.docxtemplater(zip, {
                paragraphLoop: true,
                linebreaks: true,
                delimiters: {start: '{', end: '}'},
                nullGetter: () => { return ""; },
                parser: (tag) => {
                    return {
                        get: (scope) => {
                            if (tag === '.') return scope;
                            const keys = tag.split('.');
                            let value = scope;
                            for (let i = 0; i < keys.length; i++) {
                                if (value === undefined || value === null) return '';
                                value = value[keys[i]];
                            }
                            return value;
                        }
                    };
                }
            });

            doc.render(recordData);
            
            const baseName = recordData.Name || recordData.QuoteNumber || recordData.CaseNumber || recordData.Subject || 'Document';
            const isPPT = templateType === 'PowerPoint';

            if (isPPT) {
                // PowerPoint is always download for now as we don't have a PPT-to-PDF engine
                const outZip = doc.getZip().generate({ type: 'blob' });
                window.saveAs(outZip, baseName + '.pptx');
                this.showToast('Success', 'PowerPoint downloaded.', 'success');
                this.isLoading = false;
            } else {
                // Word DOCX -> Send to PDF Engine
                this.showToast('Info', 'Generating PDF...', 'info');
                const docxBuffer = doc.getZip().generate({ type: 'arraybuffer' });
                const iframe = this.template.querySelector('iframe');
                
                if (!iframe) throw new Error('PDF Engine iframe not found.');

                iframe.contentWindow.postMessage({
                    type: 'generate',
                    blob: docxBuffer,
                    fileName: baseName,
                    mode: this.outputMode // Pass mode: 'download' or 'save'
                }, '*');
            }

        } catch (e) {
            console.error('DocGen Error Detailed:', e);
            let msg = e.message || 'Unknown error during generation';
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
            if (this.outputMode === 'save' && event.data.blob) {
                await this.saveToSalesforce(event.data.fileName, event.data.blob);
            } else {
                this.showToast('Success', 'PDF Generated successfully.', 'success');
                this.isLoading = false;
            }
        } else if (event.data.type === 'docgen_error') {
            this.error = 'PDF Engine Error: ' + event.data.message;
            this.isLoading = false;
        }
    }

    async saveToSalesforce(fileName, blob) {
        try {
            this.showToast('Info', 'Saving to Record...', 'info');
            // Convert ArrayBuffer/Blob to Base64
            const base64 = await this.blobToBase64(blob);
            await saveGeneratedDocument({
                recordId: this.recordId,
                fileName: fileName,
                base64Data: base64
            });
            this.showToast('Success', 'Document saved to record.', 'success');
        } catch (e) {
            this.error = 'Save Error: ' + (e.body ? e.body.message : e.message);
        } finally {
            this.isLoading = false;
        }
    }

    blobToBase64(blob) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onloadend = () => {
                const base64String = reader.result.split(',')[1];
                resolve(base64String);
            };
            reader.onerror = reject;
            reader.readAsDataURL(new Blob([blob]));
        });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
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