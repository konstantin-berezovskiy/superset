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
-- One row per missing person (Contact.ampm_ismissing = 1). No names, addresses or free text.
-- Disappearance details come from the person's best MP Record: one with last-seen data first,
-- then Consolidation > Interview > other, validated first, most recently modified.
-- CRM stores date-only values as UTC midnight of the local day, so dates are shifted +12h before CAST.
SELECT
    c.ContactId                                             AS person_id,
    c.ampm_missingpersoncode                                AS person_code,
    COALESCE(sm_sex.Value, 'Unknown')                       AS sex,
    CAST(c.ampm_ageatdesappearance AS int)                  AS age_at_disappearance,
    CASE
        WHEN c.ampm_ageatdesappearance IS NULL THEN 'Unknown'
        WHEN c.ampm_ageatdesappearance < 18 THEN '0-17'
        WHEN c.ampm_ageatdesappearance < 30 THEN '18-29'
        WHEN c.ampm_ageatdesappearance < 45 THEN '30-44'
        WHEN c.ampm_ageatdesappearance < 60 THEN '45-59'
        ELSE '60+'
    END                                                     AS age_group,
    COALESCE(nat.ampm_nameenglish, nat.ampm_name, 'Unknown') AS nationality,
    COALESCE(sm_mps.Value, 'Unknown')                       AS mp_status,
    COALESCE(sm_cs.Value, 'Unknown')                        AS case_status,
    COALESCE(ps.StageName, 'Unknown')                       AS workflow_stage,
    CASE WHEN c.ampm_death = 1 THEN 'Yes' ELSE 'No' END     AS is_dead,
    COALESCE(sm_brs.Value, 'Not assessed')                  AS all_dna_samples_collected,
    CAST(c.createdon AS date)                               AS registered_on,
    YEAR(c.createdon)                                       AS registered_year,
    ls.date_last_seen,
    ls.year_last_seen,
    CASE WHEN ls.year_last_seen IS NULL THEN 'Unknown'
         ELSE CONCAT(ls.year_last_seen / 5 * 5, '-', ls.year_last_seen / 5 * 5 + 4) END AS period_last_seen,
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
    a1.ampm_name                                            AS governorate_last_seen_ar,
    a2.ampm_name                                            AS district_last_seen_ar,
    CASE WHEN br.ampm_enforceddisappearancecode = 1 THEN 'Yes' ELSE 'No' END AS enforced_disappearance,
    ev.IncidentId                                           AS event_id,
    COALESCE(ev.ampm_nametitle, ev.title)                   AS event_name,
    COALESCE(sm_evt.Value, CASE WHEN ev.IncidentId IS NULL THEN 'No linked event' ELSE 'Unknown' END) AS event_type,
    agg_rec.record_count,
    agg_rec.interview_count,
    agg_rec.validated_record_count,
    agg_rel.family_member_count,
    agg_rel.blood_relative_count,
    agg_brs.dna_sample_count,
    agg_brs.dna_samples_collected,
    agg_brs.dna_samples_profiled,
    CASE WHEN agg_brs.dna_samples_collected > 0 THEN 'Yes' ELSE 'No' END AS has_dna_reference,
    agg_dead.death_information_count,
    CASE WHEN agg_dead.death_information_count > 0 THEN 'Yes' ELSE 'No' END AS has_death_information
FROM dbo.ContactBase c
LEFT JOIN dbo.StringMapBase sm_sex ON sm_sex.ObjectTypeCode = 2 AND sm_sex.AttributeName = 'ampm_biologicalsex' AND sm_sex.AttributeValue = c.ampm_biologicalsex AND sm_sex.LangId = 1033
LEFT JOIN dbo.StringMapBase sm_mps ON sm_mps.ObjectTypeCode = 2 AND sm_mps.AttributeName = 'ampm_missingpersonstatuscode' AND sm_mps.AttributeValue = c.ampm_missingpersonstatuscode AND sm_mps.LangId = 1033
LEFT JOIN dbo.StringMapBase sm_cs ON sm_cs.ObjectTypeCode = 2 AND sm_cs.AttributeName = 'statuscode' AND sm_cs.AttributeValue = c.statuscode AND sm_cs.LangId = 1033
LEFT JOIN dbo.StringMapBase sm_brs ON sm_brs.ObjectTypeCode = 2 AND sm_brs.AttributeName = 'ampm_allnecessarybrscollectedcode' AND sm_brs.AttributeValue = c.ampm_allnecessarybrscollectedcode AND sm_brs.LangId = 1033
LEFT JOIN dbo.ampm_countryBase nat ON nat.ampm_countryId = c.ampm_nationality1
LEFT JOIN dbo.ampm_missingpersonworkflowBase wf ON wf.bpf_contactid = c.ContactId AND wf.statecode = 0
LEFT JOIN dbo.ProcessStageBase ps ON ps.ProcessStageId = wf.ActiveStageId
OUTER APPLY (
    SELECT TOP 1 r.*
    FROM dbo.ampm_sourceofinformationBase r
    LEFT JOIN dbo.ampm_sourceofinformationtypeBase t ON t.ampm_sourceofinformationtypeId = r.ampm_type
    WHERE r.ampm_missingperson = c.ContactId
    ORDER BY
        CASE WHEN r.ampm_countrylcid IS NOT NULL OR COALESCE(r.ampm_lastsightingorcontactever, r.ampm_rangedatemin, r.ampm_cddatemax) IS NOT NULL THEN 0 ELSE 1 END,
        CASE t.ampm_code WHEN 'CONSOLIDATION' THEN 0 WHEN 'INTERVIEW' THEN 1 ELSE 2 END,
        CASE WHEN r.ampm_reviewstatus = 865890003 THEN 0 ELSE 1 END,
        r.modifiedon DESC
) br
OUTER APPLY (
    SELECT d.date_last_seen, CASE WHEN YEAR(d.date_last_seen) >= 1900 THEN YEAR(d.date_last_seen) END AS year_last_seen
    FROM (SELECT CAST(DATEADD(hour, 12, COALESCE(br.ampm_lastsightingorcontactever, br.ampm_rangedatemin, br.ampm_cddatemax)) AS date) AS date_last_seen) d
) ls
LEFT JOIN dbo.ampm_countryBase cls ON cls.ampm_countryId = br.ampm_countrylcid
LEFT JOIN dbo.ampm_adminlevel1Base a1 ON a1.ampm_adminlevel1Id = br.ampm_adminlevellc1id
LEFT JOIN dbo.ampm_adminlevel2Base a2 ON a2.ampm_adminlevel2Id = br.ampm_adminlevellc2id
LEFT JOIN dbo.IncidentBase ev ON ev.IncidentId = COALESCE(br.ampm_relatedeventid, br.ampm_neworexistingeventid)
LEFT JOIN dbo.StringMapBase sm_evt ON sm_evt.ObjectTypeCode = 112 AND sm_evt.AttributeName = 'ampm_eventtypecode' AND sm_evt.AttributeValue = ev.ampm_eventtypecode AND sm_evt.LangId = 1033
OUTER APPLY (
    SELECT COUNT(*) AS record_count,
           SUM(CASE WHEN t.ampm_code = 'INTERVIEW' THEN 1 ELSE 0 END) AS interview_count,
           SUM(CASE WHEN r.ampm_reviewstatus = 865890003 THEN 1 ELSE 0 END) AS validated_record_count
    FROM dbo.ampm_sourceofinformationBase r
    LEFT JOIN dbo.ampm_sourceofinformationtypeBase t ON t.ampm_sourceofinformationtypeId = r.ampm_type
    WHERE r.ampm_missingperson = c.ContactId
) agg_rec
OUTER APPLY (
    SELECT COUNT(DISTINCT CASE WHEN rc.ampm_externalid = 'FAMILY' THEN rel.ampm_relatedperson END) AS family_member_count,
           COUNT(DISTINCT CASE WHEN rt.ampm_bloodlink = 1 THEN rel.ampm_relatedperson END) AS blood_relative_count
    FROM dbo.ampm_relationshipBase rel
    LEFT JOIN dbo.ampm_relationshiptypeBase rt ON rt.ampm_relationshiptypeId = rel.ampm_relationshiptype
    LEFT JOIN dbo.ampm_relationshipcategoryBase rc ON rc.ampm_relationshipcategoryId = rel.ampm_relationshipcategoryid
    WHERE rel.ampm_person = c.ContactId AND rel.ampm_relatedperson <> c.ContactId AND rel.statecode = 0
) agg_rel
OUTER APPLY (
    SELECT COUNT(*) AS dna_sample_count,
           SUM(CASE WHEN b.statuscode IN (865890001, 865890002) THEN 1 ELSE 0 END) AS dna_samples_collected,
           SUM(CASE WHEN b.statuscode = 865890002 THEN 1 ELSE 0 END) AS dna_samples_profiled
    FROM dbo.ampm_brsBase b
    JOIN dbo.ampm_sourceofinformationBase r ON r.ampm_sourceofinformationId = b.ampm_collectionofinformationid
    WHERE r.ampm_missingperson = c.ContactId
) agg_brs
OUTER APPLY (
    SELECT COUNT(*) AS death_information_count
    FROM dbo.ampm_othercircumstanceinformationdeadBase d
    JOIN dbo.ampm_sourceofinformationBase r ON r.ampm_sourceofinformationId = d.ampm_collectionofinformationid
    WHERE r.ampm_missingperson = c.ContactId AND d.statecode = 0
) agg_dead
WHERE c.ampm_ismissing = 1
  AND c.statecode = 0
  AND ISNULL(c.ampm_ispersonconfidential, 0) = 0
  AND ISNULL(c.ampm_ismissingpersonsensitive, 0) = 0
