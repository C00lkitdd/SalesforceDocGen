public with sharing class DocGenService {

    // Collector for images to inject after XML processing
    private static List<Map<String, Object>> pendingImages = new List<Map<String, Object>>();
    private static Integer imageCounter = 0;

    public static Id generateDocument(Id templateId, Id recordId) {
        System.debug('Starting DocGen for Template: ' + templateId + ' Record: ' + recordId);
        pendingImages = new List<Map<String, Object>>();
        imageCounter = 0;

        Map<String, Object> dataMap;
        try {
            dataMap = DocGenController.generateDocumentData(templateId, recordId);
        } catch (Exception e) {
            throw new DocGenException('Error retrieving template data: ' + e.getMessage());
        }

        String base64File = (String) dataMap.get('templateFile');
        Object dataObj = dataMap.get('data');
        String outputFormat = (String) dataMap.get('outputFormat');
        String templateType = (String) dataMap.get('templateType');

        if (base64File == null) throw new DocGenException('Template file content is missing.');

        Map<String, Object> recordDataMap;
        if (dataObj instanceof Map<String, Object>) {
            recordDataMap = (Map<String, Object>) dataObj;
        } else if (dataObj instanceof SObject) {
            recordDataMap = ((SObject)dataObj).getPopulatedFieldsAsMap();
        } else {
            throw new DocGenException('Invalid data format.');
        }

        Blob templateBlob = EncodingUtil.base64Decode(base64File);
        Compression.ZipReader reader = new Compression.ZipReader(templateBlob);
        Compression.ZipWriter writer = new Compression.ZipWriter();

        // Collect entries for multi-pass processing
        String contentTypesXml = null;
        String relsXml = null;

        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();
            Boolean isTargetXml = false;
            if (templateType == 'Word') {
                isTargetXml = name == 'word/document.xml' ||
                              (name.startsWith('word/header') && name.endsWith('.xml')) ||
                              (name.startsWith('word/footer') && name.endsWith('.xml'));
            } else if (templateType == 'PowerPoint') {
                isTargetXml = name.startsWith('ppt/slides/slide') && name.endsWith('.xml');
            }

            if (isTargetXml) {
                Blob content = reader.extract(name);
                String xml = content.toString();
                xml = mergeRunsInTags(xml);
                xml = processXml(xml, recordDataMap);
                writer.addEntry(name, Blob.valueOf(xml));
            } else if (name == '[Content_Types].xml') {
                contentTypesXml = reader.extract(name).toString();
            } else if (name == 'word/_rels/document.xml.rels') {
                relsXml = reader.extract(name).toString();
            } else {
                writer.addEntry(name, reader.extract(name));
            }
        }

        // Inject collected images into the ZIP
        if (!pendingImages.isEmpty()) {
            // Update Content_Types if we have images
            if (contentTypesXml != null) {
                if (!contentTypesXml.contains('Extension="png"')) {
                    contentTypesXml = contentTypesXml.replace('</Types>', '<Default Extension="png" ContentType="image/png"/></Types>');
                }
                if (!contentTypesXml.contains('Extension="jpeg"') && !contentTypesXml.contains('Extension="jpg"')) {
                    contentTypesXml = contentTypesXml.replace('</Types>', '<Default Extension="jpeg" ContentType="image/jpeg"/></Types>');
                }
            }
            // Update rels with image relationships
            if (relsXml != null) {
                for (Map<String, Object> img : pendingImages) {
                    String relId = (String) img.get('relId');
                    String fileName = (String) img.get('fileName');
                    String newRel = '<Relationship Id="' + relId + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/' + fileName + '"/>';
                    relsXml = relsXml.replace('</Relationships>', newRel + '</Relationships>');
                }
            }
            // Add image blobs to ZIP
            for (Map<String, Object> img : pendingImages) {
                String fileName = (String) img.get('fileName');
                Blob imageBlob = (Blob) img.get('blob');
                writer.addEntry('word/media/' + fileName, imageBlob);
            }
        }

        // Write back Content_Types and rels (even without images, they must be in the ZIP)
        if (contentTypesXml != null) {
            writer.addEntry('[Content_Types].xml', Blob.valueOf(contentTypesXml));
        }
        if (relsXml != null) {
            writer.addEntry('word/_rels/document.xml.rels', Blob.valueOf(relsXml));
        }

        Blob resultBlob = writer.getArchive();
        String titleFormat = (String) dataMap.get('titleFormat');
        String recordName = (String) resolveValue(recordDataMap, 'Name');

        String docTitle = generateDocTitle(titleFormat, recordDataMap);
        if (docTitle == null) docTitle = recordName;

        return saveFile(resultBlob, docTitle, recordId, outputFormat, templateType);
    }

    /**
     * Preprocesses DOCX XML to merge text runs where template tags {tag} are split
     * across multiple <w:r><w:t> elements by Word's formatting engine.
     * After merging, processXml can find complete tags like {#QuoteLineItems}.
     */
    private static String mergeRunsInTags(String xml) {
        // 1. Find all <w:t...>text</w:t> elements and their text content positions
        Pattern wtPattern = Pattern.compile('<w:t(?:\\s[^>]*)?>([^<]*)</w:t>');
        Matcher m = wtPattern.matcher(xml);

        List<Integer> contentStarts = new List<Integer>();
        List<Integer> contentEnds = new List<Integer>();
        List<String> contents = new List<String>();

        while (m.find()) {
            contentStarts.add(m.start(1));
            contentEnds.add(m.end(1));
            contents.add(m.group(1));
        }

        if (contents.isEmpty()) return xml;

        // 2. Build flat text (concatenation of all <w:t> text) and segment offsets
        Integer totalLen = 0;
        List<Integer> flatOffsets = new List<Integer>();
        for (String c : contents) {
            flatOffsets.add(totalLen);
            totalLen += c.length();
        }
        String flatText = String.join(contents, '');

        // 3. Find tags where { and } are in different segments
        Boolean modified = false;
        Integer pos = 0;

        while (pos < flatText.length()) {
            Integer openBrace = flatText.indexOf('{', pos);
            if (openBrace == -1) break;
            Integer closeBrace = flatText.indexOf('}', openBrace);
            if (closeBrace == -1) break;

            // Determine which segments contain the { and }
            Integer openSeg = -1;
            Integer closeSeg = -1;
            for (Integer i = 0; i < contents.size(); i++) {
                Integer segStart = flatOffsets.get(i);
                Integer segEnd = segStart + contents.get(i).length();
                if (openBrace >= segStart && openBrace < segEnd) openSeg = i;
                if (closeBrace >= segStart && closeBrace < segEnd) closeSeg = i;
            }

            if (openSeg != -1 && closeSeg != -1 && openSeg != closeSeg) {
                modified = true;
                // Merge all text from openSeg through closeSeg into openSeg
                String merged = '';
                for (Integer i = openSeg; i <= closeSeg; i++) {
                    merged += contents.get(i);
                }
                contents.set(openSeg, merged);
                for (Integer i = openSeg + 1; i <= closeSeg; i++) {
                    contents.set(i, '');
                }
                // Recalculate flat offsets after merge
                totalLen = 0;
                for (Integer i = 0; i < contents.size(); i++) {
                    flatOffsets.set(i, totalLen);
                    totalLen += contents.get(i).length();
                }
                flatText = String.join(contents, '');
            }

            pos = closeBrace + 1;
        }

        if (!modified) return xml;

        // 4. Reconstruct XML by replacing text content (work backwards to maintain positions)
        String result = xml;
        for (Integer i = contents.size() - 1; i >= 0; i--) {
            String original = result.substring(contentStarts.get(i), contentEnds.get(i));
            if (!contents.get(i).equals(original)) {
                result = result.substring(0, contentStarts.get(i)) + contents.get(i) + result.substring(contentEnds.get(i));
            }
        }

        return result;
    }

    private static String processXml(String xml, Map<String, Object> data) {
        String output = '';
        Integer len = xml.length();
        Integer cursor = 0;
        
        while (cursor < len) {
            Integer nextTag = xml.indexOf('{', cursor);
            if (nextTag == -1) {
                output += xml.substring(cursor);
                break; 
            }
            output += xml.substring(cursor, nextTag);
            cursor = nextTag;
            
            Integer tagClose = xml.indexOf('}', cursor);
            if (tagClose == -1) {
                output += xml.substring(cursor);
                break;
            }
            
            String rawTag = xml.substring(cursor + 1, tagClose); 
            String tagContent = rawTag.trim();
            
            if (tagContent.startsWith('#')) {
                String key = tagContent.substring(1).trim();
                Integer sectionEnd = findBalancedEnd(xml, tagClose + 1, key);
                System.debug('DocGen processXml: Found section {#' + key + '}, sectionEnd=' + sectionEnd);

                if (sectionEnd == -1) {
                    System.debug('DocGen processXml: WARNING - no matching {/' + key + '} found! Tag output as literal.');
                    output += '{' + rawTag + '}';
                    cursor = tagClose + 1;
                } else {
                    // Default: Content between tags
                    Integer contentStart = tagClose + 1;
                    Integer contentEnd = sectionEnd;
                    String innerXml = xml.substring(contentStart, contentEnd);
                    
                    // Smart Table Row Expansion
                    // Check if we are inside a TR and if the loop is fully contained in it
                    Integer trStart = xml.lastIndexOf('<w:tr ', cursor); // Try with space
                    if (trStart == -1) trStart = xml.lastIndexOf('<w:tr>', cursor);
                    
                    // Find matching TR End
                    Integer trEnd = -1;
                    if (trStart != -1) {
                         trEnd = xml.indexOf('</w:tr>', trStart);
                         // Check if our loop is INSIDE this TR
                         // sectionEnd is index of start of {/Key}
                         Integer closeTagEnd = xml.indexOf('}', sectionEnd);
                         
                         if (trEnd > closeTagEnd) {
                             // Yes, the loop is fully inside this TR.
                             // Now, checking if we should expand.
                             // Expand if the start tag and end tag are in the SAME TR (implied by above)
                             // AND if we think it's intended (always true for better UX?)
                             
                             // CAUTION: If user meant cell-repetition, valid, but rare.
                             // We assume Row Repetition is preferred.
                             
                             // Redefine Inner XML to include the TR
                             // And strip the tags from it.
                             
                             contentStart = trStart;
                             contentEnd = trEnd + 7; // Length of </w:tr>
                             innerXml = xml.substring(contentStart, contentEnd);
                             
                             // Strip placeholders to prevent infinite recursion
                             // We must remove EXACTLY the tags found at `cursor` and `sectionEnd`
                             // To be safe, we reconstruct:
                             // Prefix (Before #Tag) + Suffix (After #Tag) ...
                             // Actually, simpler: replace first occurrence of those tags in the substring.
                             
                             String startTagFull = '{' + rawTag + '}';
                             innerXml = innerXml.replace(startTagFull, '');
                             
                             // Needed regex for end tag? No, construct it.
                             // We know the key.
                             // But strict replacement might fail if spaces differ.
                             // We can use the actual string from xml
                             String endTagFull = xml.substring(sectionEnd, closeTagEnd + 1);
                             innerXml = innerXml.replace(endTagFull, '');
                             
                             // Clean up output buffer: we added up to `cursor` (start of tag).
                             // We need to backtrack output to remove the prefix of the TR that we just added!
                             // output currently = ...<w:tr>...<w:tc>...
                             // We want to remove that part because `innerXml` now contains the WHOLE TR.
                             
                             // Calculate fallback amount
                             Integer overlap = cursor - contentStart; // Distance from TR Start to Tag Start
                             if (overlap > 0) {
                                  output = output.substring(0, output.length() - overlap);
                             }
                             
                             // Move cursor to end of TR
                             // Next iteration should start AFTER the </w:tr>
                             cursor = contentEnd; 

                             // NOTE: We set cursor for the loop.
                             // But we must NOT execute the default `cursor = closeTagEnd + 1` logic below.
                        } else {
                            // Loop spans across TRs or is outside TR?
                            // Default behavior (keep tags inside, repeat content)
                             cursor = xml.indexOf('}', sectionEnd) + 1;
                        }
                    } else {
                        cursor = xml.indexOf('}', sectionEnd) + 1;
                    }

                    // Process Data
                    Object val = resolveValue(data, key);
                    String sectionResult = '';
                    System.debug('DocGen processXml: Section {#' + key + '} val type: ' + (val == null ? 'NULL' : (val instanceof Map<String, Object> ? 'Map' : (val instanceof List<Object> ? 'List' : 'Other'))));

                    if (val instanceof Boolean && (Boolean)val) {
                         sectionResult = processXml(innerXml, data);
                    } else if (val instanceof Map<String, Object>) {
                        Map<String, Object> mapVal = (Map<String, Object>) val;
                         if (mapVal.containsKey('records') && mapVal.get('records') instanceof List<Object>) {
                            List<Object> records = (List<Object>) mapVal.get('records');
                            System.debug('DocGen processXml: Loop {#' + key + '} iterating ' + records.size() + ' records');
                            for (Object item : records) {
                                if (item instanceof Map<String, Object>) sectionResult += processXml(innerXml, (Map<String, Object>) item);
                            }
                        } else {
                             sectionResult = processXml(innerXml, mapVal);
                        }
                    } else if (val instanceof List<Object>) {
                         List<Object> listVal = (List<Object>) val;
                         System.debug('DocGen processXml: Loop {#' + key + '} iterating ' + listVal.size() + ' items (direct list)');
                         for (Object item : listVal) {
                              if (item instanceof Map<String, Object>) sectionResult += processXml(innerXml, (Map<String, Object>) item);
                         }
                    } else if (val != null) {
                         sectionResult = processXml(innerXml, data);
                    }
                    System.debug('DocGen processXml: Section {#' + key + '} result length: ' + sectionResult.length());
                    output += sectionResult;
                }
                
            } else if (tagContent.startsWith('/')) {
                output += '{' + rawTag + '}';
                cursor = tagClose + 1;
            } else if (tagContent.startsWith('%')) {
                // Image tag: {%FieldName} — inject image from field value
                String imageField = tagContent.substring(1).trim();
                Object val = resolveValue(data, imageField);
                System.debug('DocGen processXml: Image tag {%' + imageField + '} val null?: ' + (val == null) + ', val length: ' + (val != null ? String.valueOf(val).length() : 0));
                if (val != null) {
                    String imageXml = buildImageXml(String.valueOf(val));
                    System.debug('DocGen processXml: buildImageXml returned ' + (imageXml == null ? 'NULL' : 'XML length ' + imageXml.length()));
                    if (imageXml != null) {
                        output += imageXml;
                    }
                }
                cursor = tagClose + 1;
            } else {
                Object val = resolveValue(data, tagContent);
                if (val != null) {
                    String strVal = String.valueOf(val);
                    // Rich text containing images — inject as VML image
                    if (strVal.containsIgnoreCase('<img')) {
                        String imageXml = buildImageXml(strVal);
                        if (imageXml != null) {
                            output += imageXml;
                        }
                    }
                    // Strip remaining HTML tags (paragraphs, spans, divs) and output as text
                    else if (strVal.contains('<') && strVal.contains('>') && (strVal.containsIgnoreCase('<p') || strVal.containsIgnoreCase('<div') || strVal.containsIgnoreCase('<span') || strVal.containsIgnoreCase('<br'))) {
                        strVal = strVal.stripHtmlTags();
                        output += strVal.escapeXml();
                    }
                    else {
                        output += strVal.escapeXml();
                    }
                }
                cursor = tagClose + 1;
            }
        }
        return output;
    }
    
    private static Integer findBalancedEnd(String xml, Integer startSearch, String key) {
        Integer depth = 1;
        Integer cursor = startSearch;
        while (cursor < xml.length()) {
            Integer nextStart = xml.indexOf('{', cursor);
            if (nextStart == -1) return -1;
            Integer nextClose = xml.indexOf('}', nextStart);
            if (nextClose == -1) return -1;
            String content = xml.substring(nextStart + 1, nextClose).trim();
            if (content.equals('#' + key)) depth++;
            else if (content.equals('/' + key)) {
                depth--;
                if (depth == 0) return nextStart;
            }
            cursor = nextClose + 1;
        }
        return -1;
    }
    
    private static Object resolveValue(Map<String, Object> data, String path) {
        if (data == null) return null;
        List<String> parts = path.split('\\.');
        Object current = data;
        
        for (String part : parts) {
            if (current instanceof Map<String, Object>) {
                Map<String, Object> currentMap = (Map<String, Object>) current;
                if (currentMap.containsKey(part)) {
                    current = currentMap.get(part);
                } else {
                    // Try case-insensitive comparison
                    Boolean found = false;
                    for (String key : currentMap.keySet()) {
                        if (key.equalsIgnoreCase(part)) {
                            current = currentMap.get(key);
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        System.debug('DocGen Debug: Key "' + part + '" not found in Map. Keys: ' + currentMap.keySet());
                        return null;
                    }
                }
            } else if (current instanceof SObject) {
                 SObject sobj = (SObject) current;
                 try {
                     current = sobj.get(part);
                 } catch(Exception e) { 
                     System.debug('DocGen Debug: Error retrieving field "' + part + '" from SObject ' + sobj + ': ' + e.getMessage());
                     return null; 
                 }
            } else {
                return null;
            }
            if (current == null) return null;
        }
        return current;
    }
    
    /**
     * Builds OOXML drawing markup for an image and registers it for ZIP injection.
     * Accepts: HTML with <img> tags, Salesforce file references (/servlet/..., /sfc/..., refid=...),
     * ContentVersion IDs, or base64 data URIs.
     */
    private static String buildImageXml(String fieldValue) {
        if (String.isBlank(fieldValue)) return null;
        System.debug('DocGen buildImageXml: input length=' + fieldValue.length() + ', starts with: ' + fieldValue.left(100));

        Blob imageBlob = null;
        String ext = 'png';

        try {
            // 1. Rich text HTML containing <img> tags
            if (fieldValue.containsIgnoreCase('<img')) {
                System.debug('DocGen buildImageXml: detected <img>, calling extractImageFromHtml');
                imageBlob = extractImageFromHtml(fieldValue);
                System.debug('DocGen buildImageXml: extractImageFromHtml returned ' + (imageBlob == null ? 'NULL' : 'blob size ' + imageBlob.size()));
            }
            // 2. Base64 data URI
            else if (fieldValue.startsWith('data:image/')) {
                String base64Part = fieldValue.substringAfter(',');
                if (fieldValue.containsIgnoreCase('jpeg') || fieldValue.containsIgnoreCase('jpg')) ext = 'jpeg';
                imageBlob = EncodingUtil.base64Decode(base64Part);
            }
            // 3. Raw base64 (no data URI prefix)
            else if (fieldValue.length() > 100 && !fieldValue.contains('/') && !fieldValue.contains(' ')) {
                imageBlob = EncodingUtil.base64Decode(fieldValue);
            }
            // 4. ContentVersion ID (starts with 068)
            else if (fieldValue.startsWith('068') && fieldValue.length() >= 15) {
                List<ContentVersion> cvs = [SELECT VersionData, FileExtension FROM ContentVersion WHERE Id = :fieldValue WITH SYSTEM_MODE LIMIT 1];
                if (!cvs.isEmpty()) {
                    imageBlob = cvs[0].VersionData;
                    if (cvs[0].FileExtension != null) ext = cvs[0].FileExtension.toLowerCase();
                }
            }
            // 5. Salesforce file URL containing refid (rich text image reference)
            else if (fieldValue.containsIgnoreCase('refid=')) {
                String refId = fieldValue.substringAfterLast('refid=').substringBefore('&');
                if (String.isBlank(refId)) refId = fieldValue.substringAfterLast('refid=');
                imageBlob = fetchSalesforceImage(refId);
            }
            // 6. Salesforce servlet/sfc URL
            else if (fieldValue.containsIgnoreCase('/servlet/') || fieldValue.containsIgnoreCase('/sfc/')) {
                String docId = fieldValue.substringAfterLast('/');
                if (docId.contains('?')) docId = docId.substringBefore('?');
                imageBlob = fetchSalesforceImage(docId);
            }

            if (imageBlob == null) {
                System.debug(LoggingLevel.WARN, 'DocGen: Could not resolve image from: ' + fieldValue.left(200));
                return null;
            }

            imageCounter++;
            String relId = 'rIdImg' + imageCounter;
            String fileName = 'docgen_image_' + imageCounter + '.' + ext;

            // Register image for ZIP injection
            pendingImages.add(new Map<String, Object>{
                'relId' => relId,
                'fileName' => fileName,
                'blob' => imageBlob
            });

            // Use VML format (<w:pict>) for server-side generation.
            // Salesforce's PDF rendition API handles VML better than DrawingML (<w:drawing>).
            // 72 points per inch: 4in = 288pt, 3in = 216pt
            return '</w:t></w:r>' +
                '<w:r><w:pict>' +
                  '<v:shape xmlns:v="urn:schemas-microsoft-com:vml" ' +
                    'xmlns:o="urn:schemas-microsoft-com:office:office" ' +
                    'id="DocGenImage' + imageCounter + '" ' +
                    'type="#_x0000_t75" ' +
                    'style="width:288pt;height:216pt" ' +
                    'stroked="false" ' +
                    'o:bordertopcolor="this" o:borderleftcolor="this" o:borderbottomcolor="this" o:borderrightcolor="this">' +
                    '<v:imagedata xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" ' +
                      'r:id="' + relId + '"/>' +
                  '</v:shape>' +
                '</w:pict></w:r><w:r><w:t xml:space="preserve">';

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Image injection error: ' + e.getMessage());
            return null;
        }
    }

    /**
     * Extracts the first image from rich text HTML.
     * Handles data URIs, Salesforce servlet URLs (via Named Credential callout), and refid references.
     */
    private static Blob extractImageFromHtml(String html) {
        // Use string parsing instead of regex to avoid "Regex too complicated" on large base64 data
        Integer imgIdx = html.indexOfIgnoreCase('<img');
        if (imgIdx == -1) return null;

        Integer srcIdx = html.indexOfIgnoreCase('src=', imgIdx);
        if (srcIdx == -1) return null;

        srcIdx += 4; // skip 'src='
        // Skip optional whitespace
        while (srcIdx < html.length() && html.substring(srcIdx, srcIdx + 1) == ' ') srcIdx++;

        // Determine quote character
        String quoteChar = html.substring(srcIdx, srcIdx + 1);
        if (quoteChar != '"' && quoteChar != '\'') return null;
        srcIdx++; // skip opening quote

        Integer srcEnd = html.indexOf(quoteChar, srcIdx);
        if (srcEnd == -1) return null;

        String src = html.substring(srcIdx, srcEnd).replace('&amp;', '&');

        // Data URI
        if (src.startsWith('data:image/')) {
            String base64Part = src.substringAfter(',');
            return EncodingUtil.base64Decode(base64Part);
        }

        // Salesforce rtaImage servlet URL — fetch via Named Credential
        if (src.containsIgnoreCase('servlet/rtaImage')) {
            return fetchViaNamedCredential('/servlet/' + src.substringAfter('/servlet/'));
        }

        // Other Salesforce servlet/sfc URL
        if (src.containsIgnoreCase('/servlet/') || src.containsIgnoreCase('/sfc/')) {
            return fetchViaNamedCredential(src.contains('://') ? src.substringAfter('.com') : src);
        }

        // Salesforce refid reference (fallback)
        if (src.containsIgnoreCase('refid=')) {
            String refId = src.substringAfterLast('refid=').substringBefore('&');
            if (String.isBlank(refId)) refId = src.substringAfterLast('refid=');
            return fetchSalesforceImage(refId);
        }

        return null;
    }

    /**
     * Fetches a resource from the same org via the DocGen_Loopback Named Credential.
     */
    private static Blob fetchViaNamedCredential(String path) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:DocGen_Loopback' + path);
            req.setMethod('GET');
            req.setTimeout(15000);
            Http h = new Http();
            HttpResponse res = h.send(req);
            if (res.getStatusCode() == 200) {
                return res.getBodyAsBlob();
            }
            System.debug(LoggingLevel.WARN, 'DocGen: Named Credential fetch returned ' + res.getStatusCode() + ' for: ' + path.left(200));
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Named Credential fetch failed: ' + e.getMessage());
        }
        return null;
    }

    /**
     * Fetches image blob from a Salesforce file reference (ContentDocument ID or ContentVersion ID).
     */
    private static Blob fetchSalesforceImage(String fileRef) {
        if (String.isBlank(fileRef)) return null;
        try {
            // Try as ContentVersion ID first
            if (fileRef.startsWith('068')) {
                List<ContentVersion> cvs = [SELECT VersionData FROM ContentVersion WHERE Id = :fileRef WITH SYSTEM_MODE LIMIT 1];
                if (!cvs.isEmpty()) return cvs[0].VersionData;
            }
            // Try as ContentDocument ID
            if (fileRef.startsWith('069')) {
                List<ContentDocument> docs = [SELECT LatestPublishedVersionId FROM ContentDocument WHERE Id = :fileRef WITH SYSTEM_MODE LIMIT 1];
                if (!docs.isEmpty() && docs[0].LatestPublishedVersionId != null) {
                    Id latestCvId = docs[0].LatestPublishedVersionId;
                    List<ContentVersion> cvs = [SELECT VersionData FROM ContentVersion WHERE Id = :latestCvId WITH SYSTEM_MODE LIMIT 1];
                    if (!cvs.isEmpty()) return cvs[0].VersionData;
                }
            }
            // Try as a generic ID that could be linked
            if (fileRef.length() >= 15) {
                List<ContentVersion> cvs = [SELECT VersionData FROM ContentVersion WHERE Id = :fileRef WITH SYSTEM_MODE LIMIT 1];
                if (!cvs.isEmpty()) return cvs[0].VersionData;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'DocGen: Failed to fetch image for ref: ' + fileRef + ' - ' + e.getMessage());
        }
        return null;
    }

    private static Id saveFile(Blob fileBlob, String title, Id recordId, String format, String type) {
        ContentVersion cv = new ContentVersion();
        String baseName = (title != null ? title : 'Generated_Document');
        if (!baseName.startsWith('Generated_') && title == null) baseName = 'Generated_' + baseName; 
        // Logic: specific requirements? 
        // User wants "create a title". 
        // If title provided via format, use it exactly.
        // If not, revert to old behavior: 'Generated_' + recordName.
        
        // Revised Logic:
        if (title != null) baseName = title;
        else baseName = 'Generated_' + (recordId != null ? 'Document' : 'File'); // Fallback fallback
        
        String ext = (type == 'PowerPoint') ? '.pptx' : '.docx';
        cv.Title = baseName;
        cv.PathOnClient = baseName + ext;
        cv.VersionData = fileBlob;
        cv.FirstPublishLocationId = recordId; 
        insert cv;

        // EXPERIMENT: Background PDF Rendition Hack
        // If the requested format is PDF, add to the collector for delayed background capture
        if (format == 'PDF') {
            System.debug('DocGen: Collecting Rendition Capture for ' + cv.Id);
            DocGenRenditionService.addPendingRendition(cv.Id, recordId);
        }
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id WITH USER_MODE].ContentDocumentId;
    }
    private static String generateDocTitle(String format, Map<String, Object> data) {
        if (String.isBlank(format)) return null;
        String result = format;
        Pattern p = Pattern.compile('\\{([^}]+)\\}');
        Matcher m = p.matcher(format);
        while(m.find()) {
            String key = m.group(1);
            Object val = resolveValue(data, key);
            if (val != null) {
                 result = result.replace('{' + key + '}', String.valueOf(val));
            } else {
                result = result.replace('{' + key + '}', '');
            }
        }
        return result;
    }
}