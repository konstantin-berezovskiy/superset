-- Licensed to the Apache Software Foundation (ASF) under one
-- or more contributor license agreements.  See the NOTICE file
-- distributed with this work for additional information
-- regarding copyright ownership.  The ASF licenses this file
-- to you under the Apache License, Version 2.0 (the
-- "License"); you may not use this file except in compliance
-- with the License.  You may obtain a copy of the License at
--
--   http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing,
-- software distributed under the License is distributed on an
-- "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
-- KIND, either express or implied.  See the License for the
-- specific language governing permissions and limitations
-- under the License.
-- One row per biological reference sample (BRS) collected from a relative for an in-scope missing person.
-- donor_relationship = how the donor relates to the missing person (blood relationship preferred).
SELECT
    b.ampm_brsId                                            AS sample_id,
    r.ampm_missingperson                                    AS person_id,
    b.ampm_donorid                                          AS donor_id,
    COALESCE(sm_st.Value, 'Unknown')                        AS sample_status,
    COALESCE(sm_type.Value, 'Not specified')                AS sample_type,
    COALESCE(sm_cons.Value, 'Not specified')                AS consent_form_agreed,
    CASE WHEN b.ampm_isbrstobecollectedwithhighpriority = 1 THEN 'Yes' ELSE 'No' END AS high_priority,
    CAST(DATEADD(hour, 12, b.ampm_dateofcollection) AS date) AS collected_on,
    YEAR(DATEADD(hour, 12, b.ampm_dateofcollection))        AS collected_year,
    CAST(b.createdon AS date)                               AS created_on,
    COALESCE(co.ampm_nameenglish, co.ampm_name, 'Unknown')  AS collection_country,
    COALESCE(dr.relationship_type, 'Not linked')            AS donor_relationship,
    COALESCE(dr.is_blood_relative, 'No')                    AS donor_is_blood_relative,
    COALESCE(sm_sex.Value, 'Unknown')                       AS missing_person_sex
FROM dbo.ampm_brsBase b
JOIN dbo.ampm_sourceofinformationBase r ON r.ampm_sourceofinformationId = b.ampm_collectionofinformationid
JOIN dbo.ContactBase c ON c.ContactId = r.ampm_missingperson
LEFT JOIN dbo.StringMapBase sm_st ON sm_st.ObjectTypeCode = 10019 AND sm_st.AttributeName = 'statuscode' AND sm_st.AttributeValue = b.statuscode AND sm_st.LangId = 1033
LEFT JOIN dbo.StringMapBase sm_type ON sm_type.ObjectTypeCode = 10019 AND sm_type.AttributeName = 'ampm_typeofsample' AND sm_type.AttributeValue = b.ampm_typeofsample AND sm_type.LangId = 1033
LEFT JOIN dbo.StringMapBase sm_cons ON sm_cons.ObjectTypeCode = 10019 AND sm_cons.AttributeName = 'ampm_consentformagreedcode' AND sm_cons.AttributeValue = b.ampm_consentformagreedcode AND sm_cons.LangId = 1033
LEFT JOIN dbo.StringMapBase sm_sex ON sm_sex.ObjectTypeCode = 2 AND sm_sex.AttributeName = 'ampm_biologicalsex' AND sm_sex.AttributeValue = c.ampm_biologicalsex AND sm_sex.LangId = 1033
LEFT JOIN dbo.ampm_countryBase co ON co.ampm_countryId = b.ampm_countryid
OUTER APPLY (
    SELECT TOP 1
        CASE WHEN CHARINDEX('/', rt.ampm_name) > 0
             THEN LTRIM(SUBSTRING(rt.ampm_name, CHARINDEX('/', rt.ampm_name) + 1, 400))
             ELSE rt.ampm_name END AS relationship_type,
        CASE WHEN rt.ampm_bloodlink = 1 THEN 'Yes' ELSE 'No' END AS is_blood_relative
    FROM dbo.ampm_relationshipBase rel
    JOIN dbo.ampm_relationshiptypeBase rt ON rt.ampm_relationshiptypeId = rel.ampm_relationshiptype
    WHERE rel.ampm_person = r.ampm_missingperson AND rel.ampm_relatedperson = b.ampm_donorid AND rel.statecode = 0
    ORDER BY CASE WHEN rt.ampm_bloodlink = 1 THEN 0 ELSE 1 END, rel.createdon
) dr
WHERE c.ampm_ismissing = 1
  AND c.statecode = 0
  AND ISNULL(c.ampm_ispersonconfidential, 0) = 0
  AND ISNULL(c.ampm_ismissingpersonsensitive, 0) = 0
