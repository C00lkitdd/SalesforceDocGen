global with sharing class DocGenBulkFlowAction {
    
    global class Request {
        @InvocableVariable(label='Template ID' required=true)
        global Id templateId;
        
        @InvocableVariable(label='Query Condition' description='Optional SOQL WHERE clause (e.g. Type = \'Customer\')')
        global String queryCondition;
    }
    
    global class Response {
        @InvocableVariable(label='Job ID')
        global Id jobId;
        
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(label='Generate Bulk Documents' description='Starts a batch job to generate documents for multiple records based on a template and condition.')
    global static List<Response> generateBulkDocuments(List<Request> requests) {
        List<Response> responses = new List<Response>();
        
        for (Request req : requests) {
            Response res = new Response();
            try {
                // Leverage existing Bulk Controller logic
                Id jobId = DocGenBulkController.submitJob(req.templateId, req.queryCondition);
                res.jobId = jobId;
            } catch (Exception e) {
                res.errorMessage = e.getMessage();
                System.debug('DocGen Bulk Flow Error: ' + e.getStackTraceString());
            }
            responses.add(res);
        }
        
        return responses;
    }
}
