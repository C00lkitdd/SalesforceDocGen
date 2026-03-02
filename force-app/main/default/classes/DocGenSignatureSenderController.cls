public with sharing class DocGenSignatureSenderController {

    public class SignerResult {
        @AuraEnabled public String signerName;
        @AuraEnabled public String roleName;
        @AuraEnabled public String signerUrl;
        @AuraEnabled public String signerEmail;
    }

    @AuraEnabled(cacheable=true)
    public static List<ContentVersion> getRelatedDocuments(Id recordId) {
        List<ContentDocumentLink> links = [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :recordId WITH USER_MODE];
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink link : links) docIds.add(link.ContentDocumentId);

        return [
            SELECT Id, Title, FileExtension, ContentDocumentId
            FROM ContentVersion
            WHERE ContentDocumentId IN :docIds AND IsLatest = true
            AND FileExtension IN ('docx', 'pdf')
            WITH USER_MODE
            ORDER BY CreatedDate DESC
        ];
    }

    /**
     * Creates a multi-signer signature request with individual tokens per signer.
     * signersJson: [{roleName, contactId, signerName, signerEmail}, ...]
     */
    @AuraEnabled
    public static List<SignerResult> createMultiSignerRequest(Id contentDocumentId, String relatedRecordId, String signersJson) {
        // Resolve latest ContentVersionId
        List<ContentDocument> docs = [SELECT LatestPublishedVersionId FROM ContentDocument WHERE Id = :contentDocumentId WITH SYSTEM_MODE LIMIT 1];
        if (docs.isEmpty()) {
            throw new AuraHandledException('Document not found or has been deleted.');
        }
        Id contentVersionId = docs[0].LatestPublishedVersionId;

        // Parse signers JSON
        List<Map<String, Object>> signerInputs = (List<Map<String, Object>>) JSON.deserializeUntyped(signersJson);

        // Create parent request
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c();
        req.Source_Document_Id__c = contentVersionId;
        req.Related_Record_Id__c = relatedRecordId;
        req.Status__c = 'Sent';
        insert req;

        // Create individual signer records
        String siteUrl = getSiteBaseUrl();
        List<DocGen_Signer__c> signerRecords = new List<DocGen_Signer__c>();
        List<SignerResult> results = new List<SignerResult>();

        for (Integer i = 0; i < signerInputs.size(); i++) {
            Map<String, Object> input = signerInputs[i];
            String signerName = (String) input.get('signerName');
            String signerEmail = (String) input.get('signerEmail');
            String roleName = (String) input.get('roleName');
            String contactId = (String) input.get('contactId');

            // Generate unique token per signer
            Blob hash = Crypto.generateDigest('SHA-256',
                Blob.valueOf(String.valueOf(System.now().getTime()) + Math.random() + signerEmail + i)
            );
            String token = EncodingUtil.convertToHex(hash);

            DocGen_Signer__c signer = new DocGen_Signer__c();
            signer.Signature_Request__c = req.Id;
            signer.Role_Name__c = roleName;
            signer.Signer_Name__c = signerName;
            signer.Signer_Email__c = signerEmail;
            signer.Secure_Token__c = token;
            signer.Status__c = 'Pending';
            signer.Sort_Order__c = i + 1;
            if (String.isNotBlank(contactId)) {
                signer.Contact__c = contactId;
            }
            signerRecords.add(signer);

            SignerResult sr = new SignerResult();
            sr.signerName = signerName;
            sr.roleName = roleName;
            sr.signerEmail = signerEmail;
            sr.signerUrl = siteUrl + '/apex/DocGenSignature?token=' + token;
            results.add(sr);
        }

        insert signerRecords;
        return results;
    }

    /**
     * Legacy single-signer request creation (backward compat).
     */
    @AuraEnabled
    public static String createSignatureRequest(Id contentDocumentId, String relatedRecordId, String signerName, String signerEmail) {
        List<ContentDocument> docs = [SELECT LatestPublishedVersionId FROM ContentDocument WHERE Id = :contentDocumentId WITH SYSTEM_MODE LIMIT 1];
        if (docs.isEmpty()) {
            throw new AuraHandledException('Document not found or has been deleted.');
        }
        Id contentVersionId = docs[0].LatestPublishedVersionId;

        Blob hash = Crypto.generateDigest('SHA-256', Blob.valueOf(String.valueOf(System.now().getTime()) + Math.random() + signerEmail));
        String token = EncodingUtil.convertToHex(hash);

        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c();
        req.Signer_Name__c = signerName;
        req.Signer_Email__c = signerEmail;
        req.Source_Document_Id__c = contentVersionId;
        req.Related_Record_Id__c = relatedRecordId;
        req.Secure_Token__c = token;
        req.Status__c = 'Sent';
        insert req;

        return getSiteBaseUrl() + '/apex/DocGenSignature?token=' + token;
    }

    /**
     * Returns available signer role picklist values.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getSignerRolePicklistValues() {
        List<Map<String, String>> options = new List<Map<String, String>>();
        Schema.DescribeFieldResult fieldResult = DocGen_Signer__c.Role_Name__c.getDescribe();
        for (Schema.PicklistEntry entry : fieldResult.getPicklistValues()) {
            if (entry.isActive()) {
                options.add(new Map<String, String>{
                    'label' => entry.getLabel(),
                    'value' => entry.getValue()
                });
            }
        }
        return options;
    }

    /**
     * Returns all saved signature templates.
     */
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Signature_Template__c> getSignatureTemplates() {
        return [SELECT Id, Name, Description__c FROM DocGen_Signature_Template__c WITH USER_MODE ORDER BY Name ASC];
    }

    /**
     * Returns roles for a specific template.
     */
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Signature_Template_Role__c> getTemplateRoles(Id templateId) {
        return [
            SELECT Id, Role_Name__c, Sort_Order__c
            FROM DocGen_Signature_Template_Role__c
            WHERE Signature_Template__c = :templateId
            WITH USER_MODE
            ORDER BY Sort_Order__c ASC
        ];
    }

    /**
     * Saves a set of roles as a reusable template.
     * rolesJson: [{roleName: "Husband"}, {roleName: "Wife"}, ...]
     */
    @AuraEnabled
    public static Id saveSignatureTemplate(String templateName, String rolesJson) {
        DocGen_Signature_Template__c tmpl = new DocGen_Signature_Template__c();
        tmpl.Name = templateName;
        insert tmpl;

        List<Object> roleInputs = (List<Object>) JSON.deserializeUntyped(rolesJson);
        List<DocGen_Signature_Template_Role__c> roles = new List<DocGen_Signature_Template_Role__c>();

        for (Integer i = 0; i < roleInputs.size(); i++) {
            Map<String, Object> input = (Map<String, Object>) roleInputs[i];
            DocGen_Signature_Template_Role__c role = new DocGen_Signature_Template_Role__c();
            role.Signature_Template__c = tmpl.Id;
            role.Role_Name__c = (String) input.get('roleName');
            role.Sort_Order__c = i + 1;
            roles.add(role);
        }

        insert roles;
        return tmpl.Id;
    }

    /**
     * Returns Contact Name and Email for auto-filling signer fields.
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, String> getContactInfo(Id contactId) {
        List<Contact> contacts = [SELECT Name, Email FROM Contact WHERE Id = :contactId WITH USER_MODE LIMIT 1];
        Map<String, String> result = new Map<String, String>();
        if (!contacts.isEmpty()) {
            result.put('name', contacts[0].Name);
            result.put('email', contacts[0].Email != null ? contacts[0].Email : '');
        }
        return result;
    }

    private static String getSiteBaseUrl() {
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        String siteUrl = settings.Experience_Site_Url__c;

        if (String.isBlank(siteUrl)) {
            List<Site> sites = [SELECT Id FROM Site WHERE Status = 'Active' WITH SYSTEM_MODE LIMIT 1];
            if (!sites.isEmpty()) {
                SiteDetail sd = [SELECT SecureUrl FROM SiteDetail WHERE DurableId = :sites[0].Id WITH SYSTEM_MODE LIMIT 1];
                siteUrl = sd.SecureUrl;
            }
        }

        if (String.isBlank(siteUrl)) {
            siteUrl = 'https://<CONFIGURE_SITE_URL_IN_SETUP>';
        }

        if (siteUrl.endsWith('/')) {
            siteUrl = siteUrl.substring(0, siteUrl.length() - 1);
        }

        return siteUrl;
    }
}
