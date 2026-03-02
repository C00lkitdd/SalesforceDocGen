public with sharing class DocGenBulkController {

    @AuraEnabled(cacheable=true)
    public static List<DocGen_Template__c> getBulkTemplates() {
        return [SELECT Id, Name, Base_Object_API__c, Description__c FROM DocGen_Template__c WITH USER_MODE ORDER BY Name];
    }

    @AuraEnabled
    public static Integer validateFilter(String objectName, String condition) {
        if (String.isBlank(objectName)) return 0;
        String query = 'SELECT Count() FROM ' + String.escapeSingleQuotes(objectName);
        if (String.isNotBlank(condition)) {
            query += ' WHERE ' + condition;
        }
        return Database.countQuery(query);
    }

    @AuraEnabled
    public static Id submitJob(Id templateId, String condition) {
        try {
            // 1. Create Job Record
            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = templateId,
                Query_Condition__c = condition,
                Status__c = 'Queued'
            );
            insert job;

            // 2. Run Batch
            // Batch Size 1: each record needs its own transaction so callouts
            // (rich text image resolution) happen before DML (ContentVersion insert).
            // Salesforce blocks callouts after uncommitted DML in the same transaction.
            DocGenBatch batch = new DocGenBatch(job.Id);
            Database.executeBatch(batch, 1);

            return job.Id;
        } catch (Exception e) {
            throw new AuraHandledException('Error starting job: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static DocGen_Job__c getJobStatus(Id jobId) {
        return [SELECT Id, Name, Status__c, Success_Count__c, Error_Count__c, Total_Records__c FROM DocGen_Job__c WHERE Id = :jobId WITH USER_MODE];
    }

    // --- Saved Queries ---
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Saved_Query__c> getSavedQueries(Id templateId) {
        return [
            SELECT Id, Name, Description__c, Query_Condition__c 
            FROM DocGen_Saved_Query__c 
            WHERE DocGen_Template__c = :templateId 
            WITH USER_MODE
            ORDER BY CreatedDate DESC
        ];
    }

    @AuraEnabled
    public static void saveQuery(Id templateId, String label, String description, String condition) {
        try {
            DocGen_Saved_Query__c sq = new DocGen_Saved_Query__c(
                DocGen_Template__c = templateId,
                Name = label,
                Description__c = description,
                Query_Condition__c = condition
            );
            insert sq;
        } catch (Exception e) {
            throw new AuraHandledException('Error saving query: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static void deleteQuery(Id queryId) {
        try {
            delete new DocGen_Saved_Query__c(Id = queryId);
        } catch (Exception e) {
            throw new AuraHandledException('Error deleting query: ' + e.getMessage());
        }
    }
}