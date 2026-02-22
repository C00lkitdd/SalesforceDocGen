# Salesforce Document Generation Platform (Open Source)

Welcome to the **Salesforce Document Generation Platform**, a powerful, native, and completely free solution for generating documents directly within your Salesforce org. 

> [!IMPORTANT]
> This is the **first iteration (v0.1.0)** of the platform. It is fully open-source and ready for production use, but we welcome contributions and feedback to make it even better.

## Why this exists?
Normally, document generation in Salesforce is expensive. We believe that basic document needs should be accessible to everyone. This project gives you a professional-grade document engine—which others charge heavily for—entirely for free.

---

## 🚀 Quick Install (2GP Unlocked Package)

You can install the latest stable version (0.1.0-2) of the platform using the following command:

```bash
sf package install --package 04tdL000000NnUfQAK --wait 10 --installation-key-bypass
```

**Subscriber Package Version ID**: `04tdL000000NnUfQAK`  
**Installation URL**: [Click here to install](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tdL000000NnUfQAK)

---

What does this stuff do? Quick Overview Youtube: https://www.youtube.com/watch?v=TAdNItmu2jw

## 🧩 Core Components

### 1. Template Manager
The **Template Manager** is your central hub for creating and managing document templates. 
- **Access**: Navigate to the **DocGen Template Manager** tab.
- **Features**: 
    - Upload `.docx` or `.pptx` files.
    - Build SOQL queries using the built-in Query Builder.
    - Manage template versions and metadata.
    - Test generation with a sample record directly from the manager.

### 2. Record Page Generator (LWC)
Add the document generation capability to any standard or custom object record page.
- **Access**: Edit any Lightning Record Page and add the **docGenRunner** component.
- **Functionality**: Users can select a template available for that specific object and generate a PDF or PowerPoint document in one click.

### 3. Bulk Document Generation
Need to generate documents for hundreds of records at once?
- **Access**: Navigate to the **DocGen Bulk Gen** tab.
- **Features**: 
    - Filter records using an intuitive UI.
    - Track progress in real-time with a dynamic progress bar.
    - Documents are processed in the background and attached to the records automatically.

### 4. Invocable Flow Action (Single Record)
- **Developer Name**: `Generate Document (Native)`
- **Class**: `DocGenFlowAction`
- **Usage**: Use this in any Salesforce Flow (Screen or Autolaunched) to generate a document when a specific event occurs (e.g., when an Opportunity is Closed Won).

### 5. Invocable Flow Action (Bulk/Batch)
- **Developer Name**: `Generate Bulk Documents`
- **Class**: `DocGenBulkFlowAction`
- **Usage**: Ideal for **Scheduled Flows**. Pass a Template ID and an optional SOQL condition to trigger a batch job that generates documents for all matching records in the background.

---

## 🛠 Prerequisites & Setup
1. **Assign Permissions**: Assign the `DocGen Admin` or `DocGen User` permission set to yourself and your users.
2. **Assign the App**: Ensure users have access to the **DocGen** Lightning App.
3. **Files Access**: The platform uses standard Salesforce Files. Ensure users have the proper permissions to create ContentDocuments.

---

## 🤝 Contributing
This is an open-source project. We encourage you to fork this repository, submit pull requests, and report issues. Let's build the best free document engine for Salesforce together!

---

## 📄 License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
