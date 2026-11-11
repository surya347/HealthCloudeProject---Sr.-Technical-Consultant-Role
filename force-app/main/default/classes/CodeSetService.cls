/**
 * Finds or creates the Health Cloud terminology records (CodeSet / CodeSetBundle) for a coded value
 * such as SNOMED 44054006 (Type 2 diabetes) or LOINC 4548-4 (HbA1c).
 *
 * Some clinical lookups point at CodeSet and others at CodeSetBundle, and this can differ by API version,
 * so resolveFor() checks the target of the lookup field at runtime and returns the right kind of Id.
 */
public with sharing class CodeSetService {

    private static Map<String, Id> codeSetIdByCode = new Map<String, Id>();
    private static Map<Id, Id> bundleIdByCodeSetId = new Map<Id, Id>();

    public static Id resolveFor(Schema.SObjectField lookupField, String code, String display) {
        Id codeSetId = getOrCreateCodeSet(code, display);
        String targetObject = lookupField.getDescribe().getReferenceTo()[0].getDescribe().getName();
        if (targetObject == 'CodeSet') {
            return codeSetId;
        }
        return getOrCreateBundle(codeSetId, display);
    }

    public static Id getOrCreateCodeSet(String code, String display) {
        if (codeSetIdByCode.containsKey(code)) {
            return codeSetIdByCode.get(code);
        }
        List<CodeSet> existing = [SELECT Id FROM CodeSet WHERE Code = :code LIMIT 1];
        Id codeSetId;
        if (existing.isEmpty()) {
            CodeSet cs = new CodeSet(Name = display.left(255), Code = code);
            insert cs;
            codeSetId = cs.Id;
        } else {
            codeSetId = existing[0].Id;
        }
        codeSetIdByCode.put(code, codeSetId);
        return codeSetId;
    }

    public static Id getOrCreateBundle(Id codeSetId, String display) {
        if (bundleIdByCodeSetId.containsKey(codeSetId)) {
            return bundleIdByCodeSetId.get(codeSetId);
        }
        List<CodeSetBundle> existing = [SELECT Id FROM CodeSetBundle WHERE CodeSet1Id = :codeSetId LIMIT 1];
        Id bundleId;
        if (existing.isEmpty()) {
            CodeSetBundle bundle = new CodeSetBundle(Name = display.left(255), CodeSet1Id = codeSetId);
            insert bundle;
            bundleId = bundle.Id;
        } else {
            bundleId = existing[0].Id;
        }
        bundleIdByCodeSetId.put(codeSetId, bundleId);
        return bundleId;
    }
}
