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
-- One row per item of death information reported in an MP Record (no comments or coordinates).
SELECT
    d.ampm_othercircumstanceinformationdeadId               AS death_info_id,
    r.ampm_missingperson                                    AS person_id,
    COALESCE(sm_type.Value, 'Unknown')                      AS information_type,
    COALESCE(sm_st.Value, 'Unknown')                        AS information_status,
    CAST(DATEADD(hour, 12, d.ampm_date) AS date)            AS reported_date,
    CASE WHEN YEAR(DATEADD(hour, 12, d.ampm_date)) >= 1900 THEN YEAR(DATEADD(hour, 12, d.ampm_date)) END AS reported_year,
    COALESCE(co.ampm_nameenglish, co.ampm_name, 'Unknown')  AS country,
    CASE a1.ampm_name
        WHEN N'بيروت' THEN 'Beirut'
        WHEN N'جبل لبنان' THEN 'Mount Lebanon'
        WHEN N'الشمال' THEN 'North'
        WHEN N'الجنوب' THEN 'South'
        WHEN N'البقاع' THEN 'Bekaa'
        WHEN N'النبطية' THEN 'Nabatieh'
        ELSE COALESCE(a1.ampm_name, 'Unknown')
    END                                                     AS governorate,
    COALESCE(sm_sex.Value, 'Unknown')                       AS missing_person_sex
FROM dbo.ampm_othercircumstanceinformationdeadBase d
JOIN dbo.ampm_sourceofinformationBase r ON r.ampm_sourceofinformationId = d.ampm_collectionofinformationid
JOIN dbo.ContactBase c ON c.ContactId = r.ampm_missingperson
LEFT JOIN dbo.StringMapBase sm_type ON sm_type.ObjectTypeCode = 10055 AND sm_type.AttributeName = 'ampm_othercircumstanceinformationdeadcode' AND sm_type.AttributeValue = d.ampm_othercircumstanceinformationdeadcode AND sm_type.LangId = 1033
LEFT JOIN dbo.StringMapBase sm_st ON sm_st.ObjectTypeCode = 10055 AND sm_st.AttributeName = 'ampm_status' AND sm_st.AttributeValue = d.ampm_status AND sm_st.LangId = 1033
LEFT JOIN dbo.StringMapBase sm_sex ON sm_sex.ObjectTypeCode = 2 AND sm_sex.AttributeName = 'ampm_biologicalsex' AND sm_sex.AttributeValue = c.ampm_biologicalsex AND sm_sex.LangId = 1033
LEFT JOIN dbo.ampm_countryBase co ON co.ampm_countryId = d.ampm_countryid
LEFT JOIN dbo.ampm_adminlevel1Base a1 ON a1.ampm_adminlevel1Id = d.ampm_adminlevel1id
WHERE d.statecode = 0
  AND c.ampm_ismissing = 1
  AND c.statecode = 0
  AND ISNULL(c.ampm_ispersonconfidential, 0) = 0
  AND ISNULL(c.ampm_ismissingpersonsensitive, 0) = 0
