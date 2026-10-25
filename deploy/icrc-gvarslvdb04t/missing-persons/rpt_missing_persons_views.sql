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
/* =====================================================================================================
   Missing Persons reporting views for LB_MSCRM (AM/PM, Dynamics CRM 9 on SQL Server 2019)
   Proposed by the Superset deployment on gvarslvdb04t, 2026-10-24. To be reviewed and run by a DBA.

   Purpose
     A stable, documented reporting layer for Superset (and other BI tools) on top of the CRM base
     tables. Superset currently runs the same SELECTs as virtual datasets; once these views exist the
     datasets can be switched to the views without changing any chart.

   Design rules
     - Read-only, one view per business grain (person, record, relationship, DNA sample, event, death info).
     - No names, addresses, coordinates or free-text columns. Persons flagged confidential or sensitive
       are excluded (Contact.ampm_ispersonconfidential / ampm_ismissingpersonsensitive).
     - Option-set labels resolved from StringMapBase (English, LangId 1033).
     - Date-only CRM values are stored as UTC midnight of the user's day; they are shifted +12h before
       CAST(... AS date) so the calendar date is correct for UTC-12..UTC+12.

   Placement
     Views are created in a dedicated schema [rpt] so they never collide with CRM objects. Custom objects
     in a Dynamics on-premises organization database are not managed by CRM: re-create them after a CRM
     upgrade or database restore (this script is idempotent: CREATE OR ALTER).
     Alternative: create them in a separate reporting database using three-part names (LB_MSCRM.dbo.<table>).

   Access
     Grant SELECT on schema rpt to a dedicated read-only login used by Superset (recommended instead of a
     personal account); that login then needs no access to dbo.
   ===================================================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
IF SCHEMA_ID(N'rpt') IS NULL EXEC (N'CREATE SCHEMA rpt AUTHORIZATION dbo');
GO
CREATE OR ALTER VIEW rpt.mp_missing_person
AS
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
  AND ISNULL(c.ampm_ismissingpersonsensitive, 0) = 0;
GO

CREATE OR ALTER VIEW rpt.mp_record
AS
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
  AND ISNULL(c.ampm_ismissingpersonsensitive, 0) = 0;
GO

CREATE OR ALTER VIEW rpt.mp_family_link
AS
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
  AND ISNULL(c.ampm_ismissingpersonsensitive, 0) = 0;
GO

CREATE OR ALTER VIEW rpt.mp_dna_sample
AS
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
  AND ISNULL(c.ampm_ismissingpersonsensitive, 0) = 0;
GO

CREATE OR ALTER VIEW rpt.mp_event
AS
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
  AND ISNULL(ev.ampm_isconfidential, 0) = 0;
GO

CREATE OR ALTER VIEW rpt.mp_death_information
AS
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
  AND ISNULL(c.ampm_ismissingpersonsensitive, 0) = 0;
GO

/* Example grant for a dedicated Superset login (create the login/user first):
   CREATE ROLE rpt_reader;
   GRANT SELECT ON SCHEMA::rpt TO rpt_reader;
   ALTER ROLE rpt_reader ADD MEMBER [GVA\svc-superset];
*/