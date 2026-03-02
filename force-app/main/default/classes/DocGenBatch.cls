global with sharing class DocGenBatch implements Database.Batchable<SObject>, Database.Stateful, Database.AllowsCallouts {
    
    global Id jobId;
    global Id templateId;
    global String baseObject;
    global String condition;
    
    global Integer successCount = 0;
    global Integer failCount = 0;
    
    global DocGenBatch(Id jobId) {
        this.jobId = jobId;
        DocGen_Job__c job = [SELECT Template__c, Template__r.Base_Object_API__c, Query_Condition__c FROM DocGen_Job__c WHERE Id = :jobId WITH USER_MODE];
        this.templateId = job.Template__c;
        this.baseObject = job.Template__r.Base_Object_API__c;
        this.condition = job.Query_Condition__c;
    }
    
    global Database.QueryLocator start(Database.BatchableContext BC) {
        // Update Status to Processing
        update new DocGen_Job__c(Id = jobId, Status__c = 'Processing');
        
        String query = 'SELECT Id FROM ' + String.escapeSingleQuotes(baseObject);
        if (String.isNotBlank(condition)) {
            query += ' WHERE ' + condition;
        }
        query += ' WITH USER_MODE';
        
        // Count total records for progress tracking
        Integer total = Database.countQuery('SELECT Count() FROM ' + String.escapeSingleQuotes(baseObject) + (String.isNotBlank(condition) ? ' WHERE ' + condition : '') + ' WITH USER_MODE');
        update new DocGen_Job__c(Id = jobId, Status__c = 'Processing', Total_Records__c = total);
        
        return Database.getQueryLocator(query);
    }
    
    global void execute(Database.BatchableContext BC, List<SObject> scope) {
        for (SObject rec : scope) {
            try {
                DocGenService.generateDocument(templateId, rec.Id);
                successCount++;
            } catch (Exception e) {
                failCount++;
                System.debug('DocGen Batch Error for ' + rec.Id + ': ' + e.getMessage());
            }
        }
        
        // Update Job record incrementally for real-time progress tracking
        update new DocGen_Job__c(
            Id = jobId,
            Success_Count__c = successCount,
            Error_Count__c = failCount
        );

        // EXPERIMENT: Flush collected PDF rendition jobs (one per batch execute)
        // Direct enqueuing is used to preserve the user's auth context for loopback callouts
        DocGenRenditionService.enqueueRenditions(true);
    }
    
    global void finish(Database.BatchableContext BC) {
        String status = (failCount > 0) ? 'Completed with Errors' : 'Completed';
        // Note: 'Completed with Errors' not in picklist, defaulting to Completed or Failed?
        // I'll stick to 'Completed' or 'Failed' if all failed.
        if (successCount == 0 && failCount > 0) status = 'Failed';
        else status = 'Completed';
        
        DocGen_Job__c jobToUpdate = new DocGen_Job__c(
            Id = jobId, 
            Status__c = status,
            Success_Count__c = successCount,
            Error_Count__c = failCount
        );
        update jobToUpdate;
    }
}