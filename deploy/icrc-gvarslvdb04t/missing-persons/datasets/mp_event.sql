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
-- One row per event (CRM Case/Incident) with the number of in-scope missing persons linked through their MP Records.
SELECT
    ev.IncidentId                                           AS event_id,
    ev.ampm_eventcode                                       AS event_code,
    COALESCE(ev.ampm_nametitle, ev.title)                   AS event_name,
    COALESCE(sm_evt.Value, 'Unknown')                       AS event_type,
    CAST(DATEADD(hour, 12, ev.ampm_startdate) AS date)      AS start_date,
    CAST(DATEADD(hour, 12, ev.ampm_enddate) AS date)        AS end_date,
    YEAR(DATEADD(hour, 12, ev.ampm_startdate))              AS start_year,
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
    COALESCE(parent.ampm_nametitle, parent.title)           AS parent_event_name,
    COALESCE(mp.missing_person_count, 0)                    AS missing_person_count
FROM dbo.IncidentBase ev
LEFT JOIN dbo.StringMapBase sm_evt ON sm_evt.ObjectTypeCode = 112 AND sm_evt.AttributeName = 'ampm_eventtypecode' AND sm_evt.AttributeValue = ev.ampm_eventtypecode AND sm_evt.LangId = 1033
LEFT JOIN dbo.ampm_countryBase co ON co.ampm_countryId = ev.ampm_countryid
LEFT JOIN dbo.ampm_adminlevel1Base a1 ON a1.ampm_adminlevel1Id = ev.ampm_adminlevel1id
LEFT JOIN dbo.IncidentBase parent ON parent.IncidentId = ev.ampm_parentcaseid
OUTER APPLY (
    SELECT COUNT(DISTINCT r.ampm_missingperson) AS missing_person_count
    FROM dbo.ampm_sourceofinformationBase r
    JOIN dbo.ContactBase c ON c.ContactId = r.ampm_missingperson
    WHERE COALESCE(r.ampm_relatedeventid, r.ampm_neworexistingeventid) = ev.IncidentId
      AND c.ampm_ismissing = 1 AND c.statecode = 0
      AND ISNULL(c.ampm_ispersonconfidential, 0) = 0
      AND ISNULL(c.ampm_ismissingpersonsensitive, 0) = 0
) mp
WHERE ev.statecode IN (0, 1)
  AND ISNULL(ev.ampm_isconfidential, 0) = 0
