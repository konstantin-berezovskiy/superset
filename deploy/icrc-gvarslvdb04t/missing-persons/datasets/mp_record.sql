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
-- One row per MP Record (registration, interview, consolidation...) of an in-scope missing person.
SELECT
    r.ampm_sourceofinformationId                            AS record_id,
    r.ampm_missingperson                                    AS person_id,
    r.ampm_collectioncode                                   AS record_code,
    COALESCE(t.ampm_name, 'Unknown')                        AS record_type,
    COALESCE(sm_rev.Value, 'Unknown')                       AS review_status,
    COALESCE(sm_st.Value, 'Unknown')                        AS record_status,
    CAST(r.createdon AS date)                               AS created_on,
    YEAR(r.createdon)                                       AS created_year,
    CAST(DATEADD(hour, 12, r.ampm_validationdate) AS date)  AS validated_on,
    COALESCE(sm_sex.Value, 'Unknown')                       AS sex,
    COALESCE(ic.ampm_nameenglish, ic.ampm_name, 'Unknown')  AS interview_country,
    CASE ia1.ampm_name
        WHEN N'بيروت' THEN 'Beirut'
        WHEN N'جبل لبنان' THEN 'Mount Lebanon'
        WHEN N'الشمال' THEN 'North'
        WHEN N'الجنوب' THEN 'South'
        WHEN N'البقاع' THEN 'Bekaa'
        WHEN N'النبطية' THEN 'Nabatieh'
        ELSE COALESCE(ia1.ampm_name, 'Unknown')
    END                                                     AS interview_governorate,
    COALESCE(cls.ampm_nameenglish, cls.ampm_name, 'Unknown') AS country_last_seen,
    CASE a1.ampm_name
        WHEN N'بيروت' THEN 'Beirut'
        WHEN N'جبل لبنان' THEN 'Mount Lebanon'
        WHEN N'الشمال' THEN 'North'
        WHEN N'الجنوب' THEN 'South'
        WHEN N'البقاع' THEN 'Bekaa'
        WHEN N'النبطية' THEN 'Nabatieh'
        ELSE COALESCE(a1.ampm_name, 'Unknown')
    END                                                     AS governorate_last_seen,
    ls.date_last_seen,
    CASE WHEN YEAR(ls.date_last_seen) >= 1900 THEN YEAR(ls.date_last_seen) END AS year_last_seen,
    CASE WHEN r.ampm_enforceddisappearancecode = 1 THEN 'Yes' ELSE 'No' END AS enforced_disappearance,
    ev.IncidentId                                           AS event_id,
    COALESCE(ev.ampm_nametitle, ev.title)                   AS event_name
FROM dbo.ampm_sourceofinformationBase r
JOIN dbo.ContactBase c ON c.ContactId = r.ampm_missingperson
LEFT JOIN dbo.ampm_sourceofinformationtypeBase t ON t.ampm_sourceofinformationtypeId = r.ampm_type
LEFT JOIN dbo.StringMapBase sm_rev ON sm_rev.ObjectTypeCode = 10071 AND sm_rev.AttributeName = 'ampm_reviewstatus' AND sm_rev.AttributeValue = r.ampm_reviewstatus AND sm_rev.LangId = 1033
LEFT JOIN dbo.StringMapBase sm_st ON sm_st.ObjectTypeCode = 10071 AND sm_st.AttributeName = 'statuscode' AND sm_st.AttributeValue = r.statuscode AND sm_st.LangId = 1033
LEFT JOIN dbo.StringMapBase sm_sex ON sm_sex.ObjectTypeCode = 2 AND sm_sex.AttributeName = 'ampm_biologicalsex' AND sm_sex.AttributeValue = c.ampm_biologicalsex AND sm_sex.LangId = 1033
LEFT JOIN dbo.ampm_countryBase ic ON ic.ampm_countryId = r.ampm_interviewlocationcountry
LEFT JOIN dbo.ampm_adminlevel1Base ia1 ON ia1.ampm_adminlevel1Id = r.ampm_interviewlocationadminlevel1
LEFT JOIN dbo.ampm_countryBase cls ON cls.ampm_countryId = r.ampm_countrylcid
LEFT JOIN dbo.ampm_adminlevel1Base a1 ON a1.ampm_adminlevel1Id = r.ampm_adminlevellc1id
LEFT JOIN dbo.IncidentBase ev ON ev.IncidentId = COALESCE(r.ampm_relatedeventid, r.ampm_neworexistingeventid)
OUTER APPLY (
    SELECT CAST(DATEADD(hour, 12, COALESCE(r.ampm_lastsightingorcontactever, r.ampm_rangedatemin, r.ampm_cddatemax)) AS date) AS date_last_seen
) ls
WHERE c.ampm_ismissing = 1
  AND c.statecode = 0
  AND ISNULL(c.ampm_ispersonconfidential, 0) = 0
  AND ISNULL(c.ampm_ismissingpersonsensitive, 0) = 0
