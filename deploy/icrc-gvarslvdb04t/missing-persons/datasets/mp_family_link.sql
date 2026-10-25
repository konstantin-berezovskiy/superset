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
-- One row per active relationship "<relative> is <type> of <missing person>" (ampm_person = missing person).
-- Covers family members, interviewees and persons linked to the circumstances of disappearance.
SELECT
    rel.ampm_relationshipId                                 AS link_id,
    rel.ampm_person                                         AS person_id,
    rel.ampm_relatedperson                                  AS relative_id,
    CASE WHEN CHARINDEX('/', rt.ampm_name) > 0
         THEN LTRIM(SUBSTRING(rt.ampm_name, CHARINDEX('/', rt.ampm_name) + 1, 400))
         ELSE COALESCE(rt.ampm_name, 'Unknown') END         AS relationship_type,
    CASE rc.ampm_externalid
        WHEN 'FAMILY' THEN 'Family member'
        WHEN 'INTERVIEWEE' THEN 'Interviewee'
        WHEN 'DESAPPEARANCE' THEN 'Circumstances of disappearance'
        WHEN 'MEDIDENT' THEN 'Medical / dental'
        WHEN 'OTHER' THEN 'Other relationship'
        ELSE 'Unknown'
    END                                                     AS relationship_category,
    CASE WHEN rt.ampm_bloodlink = 1 THEN 'Yes' ELSE 'No' END AS is_blood_relative,
    CASE WHEN rel.ampm_uncertain = 1 THEN 'Yes' ELSE 'No' END AS is_uncertain,
    CASE WHEN EXISTS (
        SELECT 1 FROM dbo.ampm_brsBase b
        JOIN dbo.ampm_sourceofinformationBase r ON r.ampm_sourceofinformationId = b.ampm_collectionofinformationid
        WHERE b.ampm_donorid = rel.ampm_relatedperson AND r.ampm_missingperson = rel.ampm_person
          AND b.statuscode IN (865890001, 865890002)
    ) THEN 'Yes' ELSE 'No' END                              AS gave_dna_sample,
    COALESCE(sm_sex.Value, 'Unknown')                       AS missing_person_sex,
    CAST(rel.createdon AS date)                             AS created_on
FROM dbo.ampm_relationshipBase rel
JOIN dbo.ContactBase c ON c.ContactId = rel.ampm_person
LEFT JOIN dbo.ampm_relationshiptypeBase rt ON rt.ampm_relationshiptypeId = rel.ampm_relationshiptype
LEFT JOIN dbo.ampm_relationshipcategoryBase rc ON rc.ampm_relationshipcategoryId = rel.ampm_relationshipcategoryid
LEFT JOIN dbo.StringMapBase sm_sex ON sm_sex.ObjectTypeCode = 2 AND sm_sex.AttributeName = 'ampm_biologicalsex' AND sm_sex.AttributeValue = c.ampm_biologicalsex AND sm_sex.LangId = 1033
WHERE rel.statecode = 0
  AND rel.ampm_person = rel.ampm_missingperson
  AND rel.ampm_relatedperson <> rel.ampm_person
  AND c.ampm_ismissing = 1
  AND c.statecode = 0
  AND ISNULL(c.ampm_ispersonconfidential, 0) = 0
  AND ISNULL(c.ampm_ismissingpersonsensitive, 0) = 0
