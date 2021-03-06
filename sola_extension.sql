﻿-- Script to extend sola.sql. It should be run immediately at the completion of sola.sql. 

-- #325 - Add change tracking to approle_appgroup and appgroup_appuser tables. This will ensure
-- any changes to these tables are auditied. 
DROP TRIGGER IF EXISTS __track_changes ON system.approle_appgroup CASCADE;
DROP TRIGGER IF EXISTS __track_history ON system.approle_appgroup CASCADE;
DROP TABLE IF EXISTS system.approle_appgroup_historic CASCADE;

ALTER TABLE system.approle_appgroup
DROP COLUMN IF EXISTS rowidentifier,
DROP COLUMN IF EXISTS rowversion,
DROP COLUMN IF EXISTS change_action,
DROP COLUMN IF EXISTS change_user,
DROP COLUMN IF EXISTS change_time;

ALTER TABLE system.approle_appgroup
ADD rowidentifier character varying(40) NOT NULL DEFAULT uuid_generate_v1(),
ADD rowversion integer NOT NULL DEFAULT 0,
ADD change_action character(1) NOT NULL DEFAULT 'i'::bpchar,
ADD change_user character varying(50),
ADD change_time timestamp without time zone NOT NULL DEFAULT now();

UPDATE system.approle_appgroup 
SET rowversion = 1,
    change_user = 'db:postgres'; 

CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON system.approle_appgroup FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    
----Table system.approle_appgroup_historic used for the history of data of table system.approle_appgroup ---
CREATE TABLE system.approle_appgroup_historic
(
    approle_code character varying(20),
    appgroup_id character varying(40),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

-- Index appuser_historic_index_on_rowidentifier  --
CREATE INDEX approle_appgroup_historic_index_on_rowidentifier ON system.approle_appgroup_historic (rowidentifier);
    
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON system.approle_appgroup FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
   

DROP TRIGGER IF EXISTS __track_changes ON system.appuser_appgroup CASCADE;
DROP TRIGGER IF EXISTS __track_history ON system.appuser_appgroup CASCADE;
DROP TABLE IF EXISTS system.appuser_appgroup_historic CASCADE;

ALTER TABLE system.appuser_appgroup
DROP COLUMN IF EXISTS rowidentifier,
DROP COLUMN IF EXISTS rowversion,
DROP COLUMN IF EXISTS change_action,
DROP COLUMN IF EXISTS change_user,
DROP COLUMN IF EXISTS change_time;

ALTER TABLE system.appuser_appgroup
ADD rowidentifier character varying(40) NOT NULL DEFAULT uuid_generate_v1(),
ADD rowversion integer NOT NULL DEFAULT 0,
ADD change_action character(1) NOT NULL DEFAULT 'i'::bpchar,
ADD change_user character varying(50),
ADD change_time timestamp without time zone NOT NULL DEFAULT now();

UPDATE system.appuser_appgroup 
SET rowversion = 1,
    change_user = 'db:postgres'; 

CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON system.appuser_appgroup FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    
----Table system.appuser_appgroup_historic used for the history of data of table system.appuser_appgroup ---
CREATE TABLE system.appuser_appgroup_historic
(
    appuser_id character varying(40),
    appgroup_id character varying(40),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

-- Index appuser_historic_index_on_rowidentifier  --
CREATE INDEX appuser_appgroup_historic_index_on_rowidentifier ON system.appuser_appgroup_historic (rowidentifier);
    
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON system.appuser_appgroup FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
   
   
   
-- #326 - Add password expiry functionality to SOLA
INSERT INTO system.setting (name, vl, active, description)
SELECT 'pword-expiry-days', '90', TRUE, 'The number of days a users password remains valid'
WHERE NOT EXISTS (SELECT name FROM system.setting WHERE name = 'pword-expiry-days'); 
 
CREATE OR REPLACE VIEW system.user_pword_expiry AS 
WITH pw_change_all AS
  (SELECT u.username, u.change_time, u.change_user, u.rowversion
   FROM   system.appuser u
   WHERE NOT EXISTS (SELECT uh2.id FROM system.appuser_historic uh2
                     WHERE  uh2.username = u.username
                     AND    uh2.rowversion = u.rowversion - 1
                     AND    uh2.passwd = u.passwd)
   UNION
   SELECT uh.username, uh.change_time, uh.change_user, uh.rowversion
   FROM   system.appuser_historic uh
   WHERE NOT EXISTS (SELECT uh2.id FROM system.appuser_historic uh2
                     WHERE  uh2.username = uh.username
                     AND    uh2.rowversion = uh.rowversion - 1
                     AND    uh2.passwd = uh.passwd)),
pw_change AS
  (SELECT pall.username AS uname, 
          pall.change_time AS last_pword_change, 
          pall.change_user AS pword_change_user
   FROM   pw_change_all pall
   WHERE  pall.rowversion = (SELECT MAX(p2.rowversion)
                             FROM   pw_change_all p2
                             WHERE  p2.username = pall.username))

SELECT p.uname, p.last_pword_change, p.pword_change_user,
  CASE WHEN EXISTS (SELECT username FROM system.user_roles r
                    WHERE r.username = p.uname
                    AND   r.rolename IN ( 'ManageSecurity', 'NoPasswordExpiry')) THEN TRUE 
       ELSE FALSE END AS no_pword_expiry, 
  CASE WHEN s.vl IS NULL THEN NULL::INTEGER 
       ELSE (p.last_pword_change::DATE - now()::DATE) + s.vl::INTEGER END AS pword_expiry_days 
FROM pw_change p LEFT OUTER JOIN system.setting s ON s.name = 'pword-expiry-days' AND s.active;

COMMENT ON VIEW system.user_pword_expiry
  IS 'Determines the number of days until the users password expires. Once the number of days reaches 0, users will not be able to log into SOLA unless they have the ManageSecurity role (i.e. role to change manage user accounts) or the NoPasswordExpiry role. To configure the number of days before a password expires, set the pword-expiry-days setting in system.setting table. If this setting is not in place, then a password expiry does not apply.';


CREATE OR REPLACE VIEW system.active_users AS 
SELECT u.username, u.passwd 
FROM system.appuser u,
     system.user_pword_expiry ex
WHERE u.active = TRUE
AND   ex.uname = u.username
AND   (COALESCE(ex.pword_expiry_days, 1) > 0
OR    ex.no_pword_expiry = TRUE); 

COMMENT ON VIEW system.active_users
  IS 'Identifies the users currently active in the system. If the users password has expired, then they are treated as inactive users, unless they are System Administrators. This view is intended to replace the system.appuser table in the SolaRealm configuration in Glassfish.';
  
-- Update the setpassword function to set the change_user field 
DROP FUNCTION IF EXISTS system.setpassword(character varying, character varying);
 
CREATE OR REPLACE FUNCTION system.setpassword(usrname character varying, pass character varying, changeuser character varying)
  RETURNS integer AS
$BODY$
DECLARE
  result int;
BEGIN
  update system.appuser set passwd = pass,
   change_user = changeuser  where username=usrName;
  GET DIAGNOSTICS result = ROW_COUNT;
  return result;
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
COMMENT ON FUNCTION system.setpassword(character varying, character varying, character varying) IS 'This function changes the password of the user.';

-- Set the change_user on the default test user account to avoid being prompted on every login
ALTER TABLE system.appuser DISABLE TRIGGER ALL; 
UPDATE system.appuser SET change_user = 'test' 
WHERE username = 'test'; 
ALTER TABLE system.appuser ENABLE TRIGGER ALL;
  
-- Add the ChangePassword role to every group if it doesn't already exist  
INSERT INTO system.approle (code, display_value, status, description) 
SELECT 'ChangePassword', 'Admin - Change Password', 'c', 'Allows a user to change their password and edit thier user name. This role should be included in every security group.' 
WHERE NOT EXISTS (SELECT code from system.approle WHERE code = 'ChangePassword'); 

INSERT INTO system.approle (code, display_value, status, description) 
SELECT 'NoPasswordExpiry', 'Admin - No Password Expiry', 'c', 'Users with this role will not be subject to a password expiry if one is in place. This role can be assigned to user accounts used by other systems to integrate with the SOLA web services.' 
WHERE NOT EXISTS (SELECT code from system.approle WHERE code = 'NoPasswordExpiry');

INSERT INTO system.approle_appgroup (approle_code, appgroup_id) 
SELECT 'ChangePassword',  id FROM system.appgroup
WHERE NOT EXISTS (SELECT approle_code FROM system.approle_appgroup
				WHERE approle_code = 'ChangePassword'
				AND   appgroup_id = id); 
				
				
-- Ticket #327 Improved function for Lodgement Statistics Report 
CREATE OR REPLACE FUNCTION application.get_work_summary(from_date DATE, to_date DATE)
  RETURNS TABLE (
      req_type VARCHAR(100), -- The service request type
      req_cat VARCHAR(100), -- The service request category type
      group_idx INT, -- Used for grouping/sorting the services by request category
      in_progress_from INT, -- Count of the services in progress as at the from_date
      on_requisition_from INT, -- Count of the services on requisition as at the from_date
      lodged INT, -- Count of the services lodged during the reporting period
      requisitioned INT, -- Count of the services requisitioned during the reporting period
      registered INT, -- Count of the services registered during the reporting period
      cancelled INT, -- Count of the services cancelled + the services associated to applications that have been rejected or lapsed
      withdrawn INT, -- Count of the serices associated to an application that was withdrawn 
      in_progress_to INT, -- Count of the services in progress as at the to_date
      on_requisition_to INT, -- Count of the services on requisition as at the to_date
      overdue INT, -- Count of the services exceeding their expected_completion_date at end of the reporting period
      overdue_apps TEXT, -- The list of applications that are overdue
      requisition_apps TEXT -- The list of applications on Requisition
) AS
$BODY$
DECLARE 
   tmp_date DATE; 
BEGIN

   IF to_date IS NULL OR from_date IS NULL THEN
      RETURN;
   END IF; 

   -- Swap the dates so the to date is after the from date
   IF to_date < from_date THEN 
      tmp_date := from_date; 
      from_date := to_date; 
      to_date := tmp_date; 
   END IF; 
   
   -- Go through to the start of the next day. 
   to_date := to_date + 1; 

   RETURN query 
   
      -- Identifies all services lodged during the reporting period. Uses the
	  -- change_time instead of lodging_datetime to ensure all datetime comparisons 
	  -- across all subqueries yield consistent results 
      WITH service_lodged AS
	   ( SELECT ser.id, ser.application_id, ser.request_type_code
         FROM   application.service ser
         WHERE  ser.change_time BETWEEN from_date AND to_date
		 AND    ser.rowversion = 1
		 UNION
         SELECT ser_hist.id, ser_hist.application_id, ser_hist.request_type_code
         FROM   application.service_historic ser_hist
         WHERE  ser_hist.change_time BETWEEN from_date AND to_date
		 AND    ser_hist.rowversion = 1),
		 
      -- Identifies all services cancelled during the reporting period. 	  
	  service_cancelled AS 
        (SELECT ser.id, ser.application_id, ser.request_type_code
         FROM   application.service ser
         WHERE  ser.change_time BETWEEN from_date AND to_date
		 AND    ser.status_code = 'cancelled'
     -- Verify that the service actually changed status 
         AND  NOT EXISTS (SELECT ser_hist.status_code 
                          FROM application.service_historic ser_hist
                          WHERE ser_hist.id = ser.id
                          AND  (ser.rowversion - 1) = ser_hist.rowversion
                          AND  ser.status_code = ser_hist.status_code )
	 -- Check the history data for cancelled services as applications returned
	 -- from requisition can cause the cancelled service record to be updated. 
		UNION
		SELECT ser.id, ser.application_id, ser.request_type_code
         FROM   application.service_historic ser
         WHERE  ser.change_time BETWEEN from_date AND to_date
		 AND    ser.status_code = 'cancelled'
     -- Verify that the service actually changed status. 
         AND  NOT EXISTS (SELECT ser_hist.status_code 
                          FROM application.service_historic ser_hist
                          WHERE ser_hist.id = ser.id
                          AND  (ser.rowversion - 1) = ser_hist.rowversion
                          AND  ser.status_code = ser_hist.status_code )),
		
      -- All services in progress at the end of the reporting period		
      service_in_progress AS (  
         SELECT ser.id, ser.application_id, ser.request_type_code, ser.expected_completion_date
	 FROM application.service ser
	 WHERE ser.change_time <= to_date
	 AND ser.status_code IN ('pending', 'lodged')
      UNION
	 SELECT ser_hist.id, ser_hist.application_id, ser_hist.request_type_code, 
	        ser_hist.expected_completion_date
	 FROM  application.service_historic ser_hist,
	       application.service ser
	 WHERE ser_hist.change_time <= to_date
	 AND   ser.id = ser_hist.id
	 -- Filter out any services that have not been changed since the to_date as these
	 -- would have been picked up in the first select if they were still active
	 AND   ser.change_time > to_date
	 AND   ser_hist.status_code IN ('pending', 'lodged')
	 AND   ser_hist.rowversion = (SELECT MAX(ser_hist2.rowversion)
				      FROM  application.service_historic ser_hist2
				      WHERE ser_hist.id = ser_hist2.id
				      AND   ser_hist2.change_time <= to_date )),
	
    -- All services in progress at the start of the reporting period	
	service_in_progress_from AS ( 
     SELECT ser.id, ser.application_id, ser.request_type_code, ser.expected_completion_date
	 FROM application.service ser
	 WHERE ser.change_time <= from_date
	 AND ser.status_code IN ('pending', 'lodged')
     UNION
	 SELECT ser_hist.id, ser_hist.application_id, ser_hist.request_type_code, 
	        ser_hist.expected_completion_date
	 FROM  application.service_historic ser_hist,
	       application.service ser
	 WHERE ser_hist.change_time <= from_date
	 AND   ser.id = ser_hist.id
	 -- Filter out any services that have not been changed since the from_date as these
	 -- would have been picked up in the first select if they were still active
	 AND   ser.change_time > from_date
	 AND   ser_hist.status_code IN ('pending', 'lodged')
	 AND   ser_hist.rowversion = (SELECT MAX(ser_hist2.rowversion)
				      FROM  application.service_historic ser_hist2
				      WHERE ser_hist.id = ser_hist2.id
				      AND   ser_hist2.change_time <= from_date )),
				      
    app_changed AS ( -- All applications that changed status during the reporting period
	                 -- If the application changed status more than once, it will be listed
					 -- multiple times
         SELECT app.id, 
	 -- Flag if the application was withdrawn
	 app.status_code,
	 CASE app.action_code WHEN 'withdrawn' THEN TRUE ELSE FALSE END AS withdrawn
	 FROM   application.application app
	 WHERE  app.change_time BETWEEN from_date AND to_date
	 -- Verify that the application actually changed status during the reporting period
	 -- rather than just being updated
	 AND  NOT EXISTS (SELECT app_hist.status_code 
			  FROM application.application_historic app_hist
			  WHERE app_hist.id = app.id
			  AND  (app.rowversion - 1) = app_hist.rowversion
			  AND  app.status_code = app_hist.status_code )
      UNION  
	 SELECT app_hist.id, 
	 app_hist.status_code,
	 CASE app_hist.action_code WHEN 'withdrawn' THEN TRUE ELSE FALSE END AS withdrawn
	 FROM  application.application_historic app_hist
	 WHERE app_hist.change_time BETWEEN from_date AND to_date
	 -- Verify that the application actually changed status during the reporting period
	 -- rather than just being updated
	 AND  NOT EXISTS (SELECT app_hist2.status_code 
			  FROM application.application_historic app_hist2
			  WHERE app_hist.id = app_hist2.id
			  AND  (app_hist.rowversion - 1) = app_hist2.rowversion
			  AND  app_hist.status_code = app_hist2.status_code )), 
                          
     app_in_progress AS ( -- All applications in progress at the end of the reporting period
	 SELECT app.id, app.status_code, app.expected_completion_date, app.nr
	 FROM application.application app
	 WHERE app.change_time <= to_date
	 AND app.status_code IN ('lodged', 'requisitioned')
	 UNION
	 SELECT app_hist.id, app_hist.status_code, app_hist.expected_completion_date, app_hist.nr
	 FROM  application.application_historic app_hist, 
	       application.application app
	 WHERE app_hist.change_time <= to_date
	 AND   app.id = app_hist.id
	 -- Filter out any applications that have not been changed since the to_date as these
	 -- would have been picked up in the first select if they were still active
	 AND   app.change_time > to_date
	 AND   app_hist.status_code IN ('lodged', 'requisitioned')
	 AND   app_hist.rowversion = (SELECT MAX(app_hist2.rowversion)
				      FROM  application.application_historic app_hist2
				      WHERE app_hist.id = app_hist2.id
				      AND   app_hist2.change_time <= to_date)),
					  
	app_in_progress_from AS ( -- All applications in progress at the start of the reporting period
	 SELECT app.id, app.status_code, app.expected_completion_date, app.nr
	 FROM application.application app
	 WHERE app.change_time <= from_date
	 AND app.status_code IN ('lodged', 'requisitioned')
	 UNION
	 SELECT app_hist.id, app_hist.status_code, app_hist.expected_completion_date, app_hist.nr
	 FROM  application.application_historic app_hist,
	       application.application app
	 WHERE app_hist.change_time <= from_date
	 AND   app.id = app_hist.id
	-- Filter out any applications that have not been changed since the from_date as these
	-- would have been picked up in the first select if they were still active
	 AND   app.change_time > from_date
	 AND   app_hist.status_code IN ('lodged', 'requisitioned')
	 AND   app_hist.rowversion = (SELECT MAX(app_hist2.rowversion)
				      FROM  application.application_historic app_hist2
				      WHERE app_hist.id = app_hist2.id
				      AND   app_hist2.change_time <= from_date))
   -- MAIN QUERY                         
   SELECT get_translation(req.display_value, null) AS req_type,
	  CASE req.request_category_code 
	     WHEN 'registrationServices' THEN get_translation(cat.display_value, null)
	     WHEN 'cadastralServices' THEN get_translation(cat.display_value, null)
	     ELSE 'Information Services'  END AS req_cat,
	     
	  CASE req.request_category_code 
	     WHEN 'registrationServices' THEN 1
             WHEN 'cadastralServices' THEN 2
	     ELSE 3 END AS group_idx,
		 
	  -- Count of the pending and lodged services associated with
	  -- lodged applications at the start of the reporting period
         (SELECT COUNT(s.id) FROM service_in_progress_from s, app_in_progress_from a
          WHERE s.application_id = a.id
          AND   a.status_code = 'lodged'
	  AND request_type_code = req.code)::INT AS in_progress_from,

	  -- Count of the services associated with requisitioned 
	  -- applications at the end of the reporting period
         (SELECT COUNT(s.id) FROM service_in_progress_from s, app_in_progress_from a
	  WHERE s.application_id = a.id
          AND   a.status_code = 'requisitioned'
	  AND s.request_type_code = req.code)::INT AS on_requisition_from,
	     
	  -- Count the services lodged during the reporting period.
	 (SELECT COUNT(s.id) FROM service_lodged s
	  WHERE s.request_type_code = req.code)::INT AS lodged,
	  
      -- Count the applications that were requisitioned during the
	  -- reporting period. All of the services on the application
 	  -- are requisitioned unless they are cancelled. Use the
	  -- current set of services on the application, but ensure
	  -- the services where lodged before the end of the reporting
	  -- period and that they were not cancelled during the 
	  -- reporting period. 
	 (SELECT COUNT(s.id) FROM app_changed a, application.service s
          WHERE s.application_id = a.id
	  AND   a.status_code = 'requisitioned'
	  AND   s.lodging_datetime < to_date
	  AND   NOT EXISTS (SELECT can.id FROM service_cancelled can
                        WHERE s.id = can.id)	  
          AND   s.request_type_code = req.code)::INT AS requisitioned, 
          
	  -- Count the services on applications approved/completed 
	  -- during the reporting period. Note that services cannot be
	  -- changed after the application is approved, so checking the
	  -- current state of the services is valid. 
         (SELECT COUNT(s.id) FROM app_changed a, application.service s
	  WHERE s.application_id = a.id
	  AND   a.status_code = 'approved'
	  AND   s.status_code = 'completed'
	  AND   s.request_type_code = req.code)::INT AS registered,
	  
	  -- Count of the services associated with applications 
	  -- that have been lapsed or rejected + the count of 
	  -- services cancelled during the reporting period. Note that
      -- once annulled changes to the services are not possible so
      -- checking the current state of the services is valid.
      (SELECT COUNT(tmp.id) FROM  	  
        (SELECT s.id FROM app_changed a, application.service s
		  WHERE s.application_id = a.id
		  AND   a.status_code = 'annulled'
		  AND   a.withdrawn = FALSE
		  AND   s.request_type_code = req.code
          UNION		  
		  SELECT s.id FROM app_changed a, service_cancelled s
		  WHERE s.application_id = a.id
		  AND   a.status_code != 'annulled'
		  AND   s.request_type_code = req.code) AS tmp)::INT AS cancelled, 
	  
	  -- Count of the services associated with applications
	  -- that have been withdrawn during the reporting period
	  -- Note that once annulled changes to the services are
      -- not possible so checking the current state of the services is valid. 
         (SELECT COUNT(s.id) FROM app_changed a, application.service s
	  WHERE s.application_id = a.id
	  AND   a.status_code = 'annulled'
	  AND   a.withdrawn = TRUE
	  AND   s.status_code != 'cancelled'
	  AND   s.request_type_code = req.code)::INT AS withdrawn,

	  -- Count of the pending and lodged services associated with
	  -- lodged applications at the end of the reporting period
         (SELECT COUNT(s.id) FROM service_in_progress s, app_in_progress a
          WHERE s.application_id = a.id
          AND   a.status_code = 'lodged'
	  AND request_type_code = req.code)::INT AS in_progress_to,

	  -- Count of the services associated with requisitioned 
	  -- applications at the end of the reporting period
         (SELECT COUNT(s.id) FROM service_in_progress s, app_in_progress a
	  WHERE s.application_id = a.id
          AND   a.status_code = 'requisitioned'
	  AND s.request_type_code = req.code)::INT AS on_requisition_to,

	  -- Count of the services that have exceeded thier expected
	  -- completion date and are overdue. Only counts the service 
	  -- as overdue if both the application and the service are overdue. 
         (SELECT COUNT(s.id) FROM service_in_progress s, app_in_progress a
          WHERE s.application_id = a.id
          AND   a.status_code = 'lodged'              
	  AND   a.expected_completion_date < to_date
	  AND   s.expected_completion_date < to_date
	  AND   s.request_type_code = req.code)::INT AS overdue,  

	  -- The list of overdue applications 
	 (SELECT string_agg(a.nr, ', ') FROM app_in_progress a
          WHERE a.status_code = 'lodged' 
          AND   a.expected_completion_date < to_date
          AND   EXISTS (SELECT s.application_id FROM service_in_progress s
                        WHERE s.application_id = a.id
                        AND   s.expected_completion_date < to_date
                        AND   s.request_type_code = req.code)) AS overdue_apps,   

	  -- The list of applications on Requisition
	 (SELECT string_agg(a.nr, ', ') FROM app_in_progress a
          WHERE a.status_code = 'requisitioned' 
          AND   EXISTS (SELECT s.application_id FROM service_in_progress s
                        WHERE s.application_id = a.id
                        AND   s.request_type_code = req.code)) AS requisition_apps 						
   FROM  application.request_type req, 
	 application.request_category_type cat
   WHERE req.status = 'c'
   AND   cat.code = req.request_category_code					 
   ORDER BY group_idx, req_type;
	
   END; $BODY$
   LANGUAGE plpgsql VOLATILE;


COMMENT ON FUNCTION application.get_work_summary(DATE,DATE)
IS 'Returns a summary of the services processed for a specified reporting period';

-- Create indexes to improve performance of the Lodgement Report
DROP INDEX IF EXISTS application.service_historic_id_idx;
DROP INDEX IF EXISTS application.application_historic_id_idx;

 CREATE INDEX service_historic_id_idx
  ON application.service_historic
  USING btree
  (id COLLATE pg_catalog."default");

CREATE INDEX application_historic_id_idx
  ON application.application_historic
  USING btree
  (id COLLATE pg_catalog."default");




-- #338 - New Service for Mapping existing Parcel (existing Title)
--  added to the reference data new service and its required document 
DELETE from application.request_type where code = 'mapExistingParcel';
INSERT INTO application.request_type(
            code, request_category_code, display_value, description, status, 
            nr_days_to_complete, base_fee, area_base_fee, value_base_fee, 
            nr_properties_required, notation_template)
    VALUES ('mapExistingParcel','registrationServices', 'Map Existing Parcel', '', 'c', 30, 
            0.00, 0.00, 0.00, 0, 
            'Allows to make changes to the cadastre');
DELETE FROM application.request_type_requires_source_type WHERE request_type_code = 'mapExistingParcel';
insert into application.request_type_requires_source_type(source_type_code, request_type_code) values('cadastralSurvey', 'mapExistingParcel');
DELETE FROM application.request_type_requires_source_type WHERE request_type_code = 'newDigitalTitle';
INSERT INTO application.request_type_requires_source_type (request_type_code, source_type_code) VALUES('newDigitalTitle', 'title');





--- #345 - CHANGES FOR SYSTEMATIC REGISTRATION -----------------------------------------

UPDATE application.request_type SET nr_properties_required = 0 WHERE code = 'systematicRegn';


ALTER TABLE source.source ALTER reference_nr TYPE character varying(255);
ALTER TABLE source.source_historic ALTER reference_nr TYPE character varying(255);

---------   VIEW administrative.systematic_registration_listing -----------------
CREATE OR REPLACE VIEW administrative.systematic_registration_listing AS 
SELECT DISTINCT co.id, co.name_firstpart, co.name_lastpart, sa.size, 
get_translation(lu.display_value, NULL::character varying) AS land_use_code, su.ba_unit_id, 
(bu.name_firstpart::text || '/'::text) || bu.name_lastpart::text AS name
   FROM cadastre.land_use_type lu, cadastre.cadastre_object co, cadastre.spatial_value_area sa, 
   administrative.ba_unit_contains_spatial_unit su, 
   application.application aa, application.service s, administrative.ba_unit bu,
   transaction.transaction t
  WHERE sa.spatial_unit_id::text = co.id::text 
   AND bu.transaction_id = t.id
   AND t.from_service_id = s.id
   AND sa.type_code::text = 'officialArea'::text
   AND su.spatial_unit_id::text = sa.spatial_unit_id::text 
   AND s.application_id::text = aa.id::text AND s.request_type_code::text = 'systematicRegn'::text 
   AND s.status_code::text = 'completed'::text 
   AND COALESCE(co.land_use_code, 'residential'::character varying)::text = lu.code::text AND bu.id::text = su.ba_unit_id::text;

ALTER TABLE administrative.systematic_registration_listing OWNER TO postgres;

--------  VIEW administrative.sys_reg_owner_name -------------
CREATE OR REPLACE VIEW administrative.sys_reg_owner_name AS 
         SELECT (pp.name::text || ' '::text) || COALESCE(pp.last_name, ''::character varying)::text AS value, pp.name::text AS name, COALESCE(pp.last_name, ''::character varying)::text AS last_name, co.id, co.name_firstpart, co.name_lastpart, get_translation(lu.display_value, NULL::character varying) AS land_use_code, su.ba_unit_id, sa.size, 
                CASE
                    WHEN COALESCE(co.land_use_code, 'residential'::character varying)::text = 'residential'::text THEN sa.size
                    ELSE 0::numeric
                END AS residential, 
                CASE
                    WHEN COALESCE(co.land_use_code, 'residential'::character varying)::text = 'agricultural'::text THEN sa.size
                    ELSE 0::numeric
                END AS agricultural, 
                CASE
                    WHEN COALESCE(co.land_use_code, 'residential'::character varying)::text = 'commercial'::text THEN sa.size
                    ELSE 0::numeric
                END AS commercial, 
                CASE
                    WHEN COALESCE(co.land_use_code, 'residential'::character varying)::text = 'industrial'::text THEN sa.size
                    ELSE 0::numeric
                END AS industrial
           FROM cadastre.land_use_type lu, cadastre.cadastre_object co, 
           cadastre.spatial_value_area sa, administrative.ba_unit_contains_spatial_unit su, 
           application.application aa, application.service s,
            party.party pp, administrative.party_for_rrr pr, administrative.rrr rrr, administrative.ba_unit bu,
          transaction.transaction t
           WHERE sa.spatial_unit_id::text = co.id::text AND sa.type_code::text = 'officialArea'::text AND su.spatial_unit_id::text = sa.spatial_unit_id::text
           AND bu.transaction_id = t.id
           AND t.from_service_id = s.id
   
           AND s.application_id::text = aa.id::text AND s.request_type_code::text = 'systematicRegn'::text AND s.status_code::text = 'completed'::text AND pp.id::text = pr.party_id::text AND pr.rrr_id::text = rrr.id::text AND rrr.ba_unit_id::text = su.ba_unit_id::text AND (rrr.type_code::text = 'ownership'::text OR rrr.type_code::text = 'apartment'::text OR rrr.type_code::text = 'commonOwnership'::text) AND bu.id::text = su.ba_unit_id::text AND COALESCE(co.land_use_code, 'residential'::character varying)::text = lu.code::text
UNION 
         SELECT DISTINCT 'No Claimant '::text AS value, 'No Claimant '::text AS name, 'No Claimant '::text AS last_name, co.id, co.name_firstpart, co.name_lastpart, get_translation(lu.display_value, NULL::character varying) AS land_use_code, su.ba_unit_id, sa.size, 
                CASE
                    WHEN COALESCE(co.land_use_code, 'residential'::character varying)::text = 'residential'::text THEN sa.size
                    ELSE 0::numeric
                END AS residential, 
                CASE
                    WHEN COALESCE(co.land_use_code, 'residential'::character varying)::text = 'agricultural'::text THEN sa.size
                    ELSE 0::numeric
                END AS agricultural, 
                CASE
                    WHEN COALESCE(co.land_use_code, 'residential'::character varying)::text = 'commercial'::text THEN sa.size
                    ELSE 0::numeric
                END AS commercial, 
                CASE
                    WHEN COALESCE(co.land_use_code, 'residential'::character varying)::text = 'industrial'::text THEN sa.size
                    ELSE 0::numeric
                END AS industrial
           FROM cadastre.land_use_type lu, cadastre.cadastre_object co, cadastre.spatial_value_area sa, administrative.ba_unit_contains_spatial_unit su,
           application.application aa, party.party pp, administrative.party_for_rrr pr, administrative.rrr rrr, application.service s, administrative.ba_unit bu,
           transaction.transaction t
          WHERE sa.spatial_unit_id::text = co.id::text AND COALESCE(co.land_use_code, 'residential'::character varying)::text = lu.code::text AND sa.type_code::text = 'officialArea'::text 
          AND bu.id::text = su.ba_unit_id::text AND su.spatial_unit_id::text = sa.spatial_unit_id::text 
          AND bu.transaction_id = t.id
          AND t.from_service_id = s.id
          AND NOT (su.ba_unit_id::text IN ( SELECT rrr.ba_unit_id
                   FROM administrative.rrr rrr, party.party pp, administrative.party_for_rrr pr
                  WHERE (rrr.type_code::text = 'ownership'::text OR rrr.type_code::text = 'apartment'::text OR rrr.type_code::text = 'commonOwnership'::text OR rrr.type_code::text = 'stateOwnership'::text) AND pp.id::text = pr.party_id::text AND pr.rrr_id::text = rrr.id::text)) AND s.application_id::text = aa.id::text AND s.request_type_code::text = 'systematicRegn'::text AND s.status_code::text = 'completed'::text
  ORDER BY 3, 2;

ALTER TABLE administrative.sys_reg_owner_name OWNER TO postgres;


-----  VIEW administrative.sys_reg_state_land  --------------
CREATE OR REPLACE VIEW administrative.sys_reg_state_land AS 
 SELECT (pp.name::text || ' '::text) || COALESCE(pp.last_name, ' '::character varying)::text AS value, co.id, co.name_firstpart, co.name_lastpart, get_translation(lu.display_value, NULL::character varying) AS land_use_code, su.ba_unit_id, sa.size, 
        CASE
            WHEN COALESCE(co.land_use_code, 'residential'::character varying)::text = 'residential'::text THEN sa.size
            ELSE 0::numeric
        END AS residential, 
        CASE
            WHEN COALESCE(co.land_use_code, 'residential'::character varying)::text = 'agricultural'::text THEN sa.size
            ELSE 0::numeric
        END AS agricultural, 
        CASE
            WHEN COALESCE(co.land_use_code, 'residential'::character varying)::text = 'commercial'::text THEN sa.size
            ELSE 0::numeric
        END AS commercial, 
        CASE
            WHEN COALESCE(co.land_use_code, 'residential'::character varying)::text = 'industrial'::text THEN sa.size
            ELSE 0::numeric
        END AS industrial
   FROM cadastre.land_use_type lu, cadastre.cadastre_object co, cadastre.spatial_value_area sa, administrative.ba_unit_contains_spatial_unit su, 
   application.application aa, application.service s, party.party pp, administrative.party_for_rrr pr, administrative.rrr rrr, administrative.ba_unit bu,
   transaction.transaction t
  WHERE sa.spatial_unit_id::text = co.id::text AND COALESCE(co.land_use_code, 'residential'::character varying)::text = lu.code::text 
  AND sa.type_code::text = 'officialArea'::text AND su.spatial_unit_id::text = sa.spatial_unit_id::text 
  AND bu.transaction_id = t.id
  AND t.from_service_id = s.id
   AND s.application_id::text = aa.id::text AND s.request_type_code::text = 'systematicRegn'::text AND s.status_code::text = 'completed'::text AND pp.id::text = pr.party_id::text AND pr.rrr_id::text = rrr.id::text AND rrr.ba_unit_id::text = su.ba_unit_id::text AND rrr.type_code::text = 'stateOwnership'::text AND bu.id::text = su.ba_unit_id::text
  ORDER BY (pp.name::text || ' '::text) || COALESCE(pp.last_name, ' '::character varying)::text;

ALTER TABLE administrative.sys_reg_state_land OWNER TO postgres;

---------- VIEW application.systematic_registration_certificates -----------
CREATE OR REPLACE VIEW application.systematic_registration_certificates AS 
 SELECT aa.nr, co.name_firstpart, co.name_lastpart, su.ba_unit_id
   FROM application.application_status_type ast, cadastre.land_use_type lu, 
   cadastre.cadastre_object co, administrative.ba_unit bu, cadastre.spatial_value_area sa, administrative.ba_unit_contains_spatial_unit su, 
   application.application aa, application.service s,
   transaction.transaction t
  WHERE sa.spatial_unit_id::text = co.id::text AND sa.type_code::text = 'officialArea'::text 
  AND su.spatial_unit_id::text = sa.spatial_unit_id::text 
  AND bu.transaction_id = t.id
  AND t.from_service_id = s.id
  AND s.application_id::text = aa.id::text 
  AND s.request_type_code::text = 'systematicRegn'::text 
  AND aa.status_code::text = ast.code::text AND aa.status_code::text = 'approved'::text 
  ;

ALTER TABLE application.systematic_registration_certificates OWNER TO postgres;


---------- FUNCTION administrative.getsysregprogress -------------------------
CREATE OR REPLACE FUNCTION administrative.getsysregprogress(fromdate character varying, todate character varying, namelastpart character varying)
  RETURNS SETOF record AS
$BODY$
DECLARE 

       	block  			varchar;	
       	TotAppLod		decimal:=0 ;	
        TotParcLoaded		varchar:='none' ;	
        TotRecObj		decimal:=0 ;	
        TotSolvedObj		decimal:=0 ;	
        TotAppPDisp		decimal:=0 ;	
        TotPrepCertificate      decimal:=0 ;	
        TotIssuedCertificate	decimal:=0 ;	


        Total  			varchar;	
       	TotalAppLod		decimal:=0 ;	
        TotalParcLoaded		varchar:='none' ;	
        TotalRecObj		decimal:=0 ;	
        TotalSolvedObj		decimal:=0 ;	
        TotalAppPDisp		decimal:=0 ;	
        TotalPrepCertificate      decimal:=0 ;	
        TotalIssuedCertificate	decimal:=0 ;	


  
      
       rec     record;
       sqlSt varchar;
       workFound boolean;
       recToReturn record;

       recTotalToReturn record;

        -- From Neil's email 9 march 2013
	    -- PROGRESS REPORT
		--0. Block	
		--1. Total Number of Applications Lodged	
		--2. No of Parcel loaded	
		--3. No of Objections received
		--4. No of Objections resolved
		--5. No of Applications in Public Display	               
		--6. No of Applications with Prepared Certificate	
		--7. No of Applications with Issued Certificate	
		
    
BEGIN  


   sqlSt:= '';
    
  
 sqlSt:= 'select   co.name_lastpart   as area
                   FROM   application.application aa,     
			  application.service s,
			  cadastre.cadastre_object co,
			  administrative.ba_unit_contains_spatial_unit su,
			  administrative.ba_unit bu,
                          transaction.transaction t             
			    WHERE s.application_id = aa.id
			    AND   bu.transaction_id = t.id
                            AND   t.from_service_id = s.id
                            AND   su.spatial_unit_id::text = co.id::text 
			    AND   su.ba_unit_id = bu.id
			    AND   bu.transaction_id = t.id
			    AND   t.from_service_id = s.id
			    AND   s.request_type_code::text = ''systematicRegn''::text
			    
    ';
    
    if namelastpart != '' then
          sqlSt:= sqlSt|| ' AND compare_strings('''||namelastpart||''', co.name_lastpart) ';
    end if;
    --raise exception '%',sqlSt;
       workFound = false;

    -- Loop through results
    
    FOR rec in EXECUTE sqlSt loop

    
    select  (      
                  ( SELECT  
		    count (distinct(aa.id)) 
		    FROM   application.application aa,     
			  application.service s,
			  cadastre.cadastre_object co,
			  administrative.ba_unit_contains_spatial_unit su,
			  administrative.ba_unit bu,
                          transaction.transaction t             
			    WHERE s.application_id = aa.id
			    AND   bu.transaction_id = t.id
                            AND   t.from_service_id = s.id
                            AND   su.spatial_unit_id::text = co.id::text 
			    AND   su.ba_unit_id = bu.id
			    AND   bu.transaction_id = t.id
			    AND   t.from_service_id = s.id
			    AND   s.request_type_code::text = 'systematicRegn'::text
			    AND   aa.action_code='lodge'
		            AND compare_strings(''|| rec.area ||'', co.name_lastpart)
                            AND  (
		          (aa.lodging_datetime  between to_date(''|| fromDate || '','yyyy-mm-dd')  and to_date(''|| toDate || '','yyyy-mm-dd'))
		           or
		          (aa.change_time  between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd'))
		          )
			    ) + 
	           ( SELECT  
		    count (distinct(aa.id)) 
		    FROM  application.application_historic aa,     
			  application.service s,
			  cadastre.cadastre_object co,
			  administrative.ba_unit_contains_spatial_unit su,
			  administrative.ba_unit bu,
                          transaction.transaction t             
			    WHERE s.application_id = aa.id
			    AND   bu.transaction_id = t.id
                            AND   t.from_service_id = s.id
                            AND   su.spatial_unit_id::text = co.id::text 
			    AND   su.ba_unit_id = bu.id
			    AND   bu.transaction_id = t.id
			    AND   t.from_service_id = s.id
			    AND   aa.action_code='lodge'
			    AND   s.request_type_code::text = 'systematicRegn'::text
		            AND compare_strings(''|| rec.area ||'', co.name_lastpart)
                    	    AND  (
		          (aa.lodging_datetime  between to_date(''|| fromDate || '','yyyy-mm-dd')  and to_date(''|| toDate || '','yyyy-mm-dd'))
		           or
		          (aa.change_time  between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd'))
		          )
			    )
		    

	      ),  --- TotApp
          (           
	   
	   (
	    SELECT count (DISTINCT co.id)
	    FROM cadastre.land_use_type lu, 
		 cadastre.cadastre_object co, 
		 cadastre.spatial_value_area sa, 
		 administrative.ba_unit_contains_spatial_unit su,
		 application.application aa, 
		 application.service s, 
		 administrative.ba_unit bu, 
		 transaction.transaction t 
		    WHERE s.application_id = aa.id
			    AND   bu.transaction_id = t.id
                            AND   t.from_service_id = s.id
                            AND   su.spatial_unit_id::text = co.id::text 
			    AND   su.ba_unit_id = bu.id
			    AND   bu.transaction_id = t.id
			    AND   t.from_service_id = s.id
			    AND   s.request_type_code::text = 'systematicRegn'::text
		            AND compare_strings(''|| rec.area ||'', co.name_lastpart)
	    AND sa.spatial_unit_id::text = co.id::text AND sa.type_code::text = 'officialArea'::text 
	    AND su.spatial_unit_id::text = sa.spatial_unit_id::text 
	    AND s.status_code::text = 'completed'::text AND COALESCE(co.land_use_code, 'residential'::character varying)::text = lu.code::text AND bu.id::text = su.ba_unit_id::text
	    )
            ||'/'||
	    (SELECT count (*)
	            FROM cadastre.cadastre_object co
			    WHERE co.type_code='parcel'
			    AND compare_strings(''|| rec.area ||'', co.name_lastpart)
                    	    
	     )

	   )
                 ,  ---TotParcelLoaded
                  
               (
                  SELECT 
                  (
	            (SELECT (COUNT(*)) 
			FROM  application.application aa, 
			  application.service s,
			  cadastre.cadastre_object co,
			  administrative.ba_unit_contains_spatial_unit su,
			  administrative.ba_unit bu,
                          transaction.transaction t             
			    WHERE s.application_id = aa.id
			    AND   bu.transaction_id = t.id
                            AND   t.from_service_id = s.id
                            AND   su.spatial_unit_id::text = co.id::text 
			    AND   su.ba_unit_id = bu.id
			    AND   bu.transaction_id = t.id
			    AND   t.from_service_id = s.id
			   AND compare_strings(''|| rec.area ||'', co.name_lastpart) 
			   AND s.application_id::text in (select s.application_id 
						 FROM application.service s
						 where s.request_type_code::text = 'systematicRegn'::text
						 ) 
			  AND s.request_type_code::text = 'lodgeObjection'::text
			  AND s.status_code::text = 'lodged'::text
			  AND  (
		          (aa.lodging_datetime  between to_date(''|| fromDate || '','yyyy-mm-dd')  and to_date(''|| toDate || '','yyyy-mm-dd'))
		           or
		          (aa.change_time  between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd'))
		          )
		        ) +
		        (SELECT (COUNT(*)) 
			FROM  application.application aa, 
			   application.service_historic s,
			  cadastre.cadastre_object co,
			  administrative.ba_unit_contains_spatial_unit su,
			  administrative.ba_unit bu,
                          transaction.transaction t             
			    WHERE s.application_id = aa.id
			    AND   bu.transaction_id = t.id
                            AND   t.from_service_id = s.id
                            AND   su.spatial_unit_id::text = co.id::text 
			    AND   su.ba_unit_id = bu.id
			    AND   bu.transaction_id = t.id
			    AND   t.from_service_id = s.id
			   AND compare_strings(''|| rec.area ||'', co.name_lastpart) 
			   AND s.application_id::text in (select s.application_id 
						 FROM application.service s
						 where s.request_type_code::text = 'systematicRegn'::text
						 ) 
			  AND s.request_type_code::text = 'lodgeObjection'::text
			  AND s.status_code::text = 'lodged'::text
			  AND  (
		          (aa.lodging_datetime  between to_date(''|| fromDate || '','yyyy-mm-dd')  and to_date(''|| toDate || '','yyyy-mm-dd'))
		           or
		          (aa.change_time  between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd'))
		          )
		        )  
		   )  
		),  --TotLodgedObj

                (
	          SELECT (COUNT(*)) 
		   FROM  application.application aa, 
		   application.service s,
			  cadastre.cadastre_object co,
			  administrative.ba_unit_contains_spatial_unit su,
			  administrative.ba_unit bu,
                          transaction.transaction t             
			    WHERE s.application_id = aa.id
			    AND   bu.transaction_id = t.id
                            AND   t.from_service_id = s.id
                            AND   su.spatial_unit_id::text = co.id::text 
			    AND   su.ba_unit_id = bu.id
			    AND   bu.transaction_id = t.id
			    AND   t.from_service_id = s.id
			    AND compare_strings(''|| rec.area ||'', co.name_lastpart) 
		            AND s.application_id::text in (select s.application_id 
						 FROM application.service s
						 where s.request_type_code::text = 'systematicRegn'::text
						 ) 
		  AND s.request_type_code::text = 'lodgeObjection'::text
		  AND s.status_code::text = 'cancelled'::text
		  AND  (
		          (aa.lodging_datetime  between to_date(''|| fromDate || '','yyyy-mm-dd')  and to_date(''|| toDate || '','yyyy-mm-dd'))
		           or
		          (aa.change_time  between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd'))
		          )
		), --TotSolvedObj
			
		(
		SELECT  
		    count (distinct(aa.id)) 
		    FROM  application.application aa,
			  application.service s,
			  cadastre.cadastre_object co,
			  administrative.ba_unit_contains_spatial_unit su,
			  administrative.ba_unit bu,
                          transaction.transaction t             
			    WHERE s.application_id = aa.id
			    AND   bu.transaction_id = t.id
                            AND   t.from_service_id = s.id
                            AND   su.spatial_unit_id::text = co.id::text 
			    AND   su.ba_unit_id = bu.id
			    AND   bu.transaction_id = t.id
			    AND   t.from_service_id = s.id
			    AND compare_strings(''|| rec.area ||'', co.name_lastpart) 
			    AND   s.request_type_code::text = 'systematicRegn'::text
			    AND co.name_lastpart in (
						      select ss.reference_nr 
						      from   source.source ss 
						      where ss.type_code='publicNotification'
						      AND ss.recordation  between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd')
                                                     )
                 ),  ---TotAppPubDispl


                 (
                  select count(distinct (aa.id))
                   from application.service s, 
                   application.application aa, 
                   cadastre.cadastre_object co,
		   administrative.ba_unit_contains_spatial_unit su,
		   administrative.ba_unit bu,
                   transaction.transaction t             
			    WHERE s.application_id = aa.id
			    AND   bu.transaction_id = t.id
                            AND   t.from_service_id = s.id
                            AND   su.spatial_unit_id::text = co.id::text 
			    AND   su.ba_unit_id = bu.id
			    AND   bu.transaction_id = t.id
			    AND   t.from_service_id = s.id
			    AND compare_strings(''|| rec.area ||'', co.name_lastpart) 
			    AND s.request_type_code::text = 'systematicRegn'::text
		            AND co.name_lastpart in (
						      select ss.reference_nr 
						      from   source.source ss 
						      where ss.type_code='publicNotification'
						      and ss.expiration_date < to_date(''|| toDate ||'','yyyy-mm-dd')
                                                      and   ss.reference_nr in ( select ss.reference_nr from   source.source ss 
										  where ss.type_code='title'
										  and ss.recordation  between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd')
										  and ss.reference_nr = ''|| rec.area ||''
                                                                                )   
					           )
	
                 ),  ---TotCertificatesPrepared
                 (select count (distinct(s.id))
                   FROM 
                       application.service s   --,
		   WHERE s.request_type_code::text = 'documentCopy'::text
		   AND s.lodging_datetime between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd')
                   AND s.action_notes = ''|| rec.area ||'')  --TotCertificatesIssued

                    
              INTO       TotAppLod,
                         TotParcLoaded,
                         TotRecObj,
                         TotSolvedObj,
                         TotAppPDisp,
                         TotPrepCertificate,
                         TotIssuedCertificate
          ;        

                block = rec.area;
                TotAppLod = TotAppLod;
                TotParcLoaded = TotParcLoaded;
                TotRecObj = TotRecObj;
                TotSolvedObj = TotSolvedObj;
                TotAppPDisp = TotAppPDisp;
                TotPrepCertificate = TotPrepCertificate;
                TotIssuedCertificate = TotIssuedCertificate;
	  
	  select into recToReturn
	       	block::			varchar,
		TotAppLod::  		decimal,	
		TotParcLoaded::  	varchar,	
		TotRecObj::  		decimal,	
		TotSolvedObj::  	decimal,	
		TotAppPDisp::  		decimal,	
		TotPrepCertificate::  	decimal,	
		TotIssuedCertificate::  decimal;	
		                         
		return next recToReturn;
		workFound = true;
          
    end loop;
   
    if (not workFound) then
         block = 'none';
                
        select into recToReturn
	       	block::			varchar,
		TotAppLod::  		decimal,	
		TotParcLoaded::  	varchar,	
		TotRecObj::  		decimal,	
		TotSolvedObj::  	decimal,	
		TotAppPDisp::  		decimal,	
		TotPrepCertificate::  	decimal,	
		TotIssuedCertificate::  decimal;		
		                         
		return next recToReturn;

    end if;

------ TOTALS ------------------
                
              select  (      
                  ( SELECT  
		    count (distinct(aa.id)) 
		    FROM  application.application aa,
			  application.service s
			    WHERE s.application_id = aa.id
			    AND   s.request_type_code::text = 'systematicRegn'::text
			    AND   aa.action_code='lodge'
                            AND  (
		          (aa.lodging_datetime  between to_date(''|| fromDate || '','yyyy-mm-dd')  and to_date(''|| toDate || '','yyyy-mm-dd'))
		           or
		          (aa.change_time  between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd'))
		          )
			    ) +
	           ( SELECT  
		    count (distinct(aa.id)) 
		    FROM  application.application_historic aa,
			  application.service s
			    WHERE s.application_id = aa.id
			    AND   s.request_type_code::text = 'systematicRegn'::text
			    AND   aa.action_code='lodge'
                            AND  (
		          (aa.lodging_datetime  between to_date(''|| fromDate || '','yyyy-mm-dd')  and to_date(''|| toDate || '','yyyy-mm-dd'))
		           or
		          (aa.change_time  between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd'))
		          )
			    )
		    

	      ),  --- TotApp

		   
	          (           
	   
	   (
	    SELECT count (DISTINCT co.id)
	    FROM cadastre.land_use_type lu, 
	    cadastre.spatial_value_area sa, 
	    application.application aa, 
	    application.service s, 
            cadastre.cadastre_object co,
	    administrative.ba_unit_contains_spatial_unit su,
	    administrative.ba_unit bu,
            transaction.transaction t             
			    WHERE s.application_id = aa.id
			    AND   bu.transaction_id = t.id
                            AND   t.from_service_id = s.id
                            AND   su.spatial_unit_id::text = co.id::text 
			    AND   su.ba_unit_id = bu.id
			    AND   bu.transaction_id = t.id
			    AND   t.from_service_id = s.id
			    AND sa.type_code::text = 'officialArea'::text 
			    AND su.spatial_unit_id::text = sa.spatial_unit_id::text 
	                    AND s.request_type_code::text = 'systematicRegn'::text 
	                    AND s.status_code::text = 'completed'::text AND COALESCE(co.land_use_code, 'residential'::character varying)::text = lu.code::text AND bu.id::text = su.ba_unit_id::text
	    )
            ||'/'||
	    (SELECT count (*)
	            FROM cadastre.cadastre_object co
			    WHERE co.type_code='parcel'
	    )

	   ),  ---TotParcelLoaded
                  
                    (
                  SELECT 
                  (
	            (SELECT (COUNT(*)) 
			FROM  application.application aa, 
			   application.service s
			  WHERE  s.application_id::text = aa.id::text 
			  AND s.application_id::text in (select s.application_id 
						 FROM application.service s
						 where s.request_type_code::text = 'systematicRegn'::text
						 ) 
			  AND s.request_type_code::text = 'lodgeObjection'::text
			  AND s.status_code::text = 'lodged'::text
			  AND  (
		          (aa.lodging_datetime  between to_date(''|| fromDate || '','yyyy-mm-dd')  and to_date(''|| toDate || '','yyyy-mm-dd'))
		           or
		          (aa.change_time  between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd'))
		          )
		        ) +
		        (SELECT (COUNT(*)) 
			FROM  application.application aa, 
			   application.service_historic s
			  WHERE  s.application_id::text = aa.id::text 
			  AND s.application_id::text in (select s.application_id 
						 FROM application.service s
						 where s.request_type_code::text = 'systematicRegn'::text
						 ) 
			  AND s.request_type_code::text = 'lodgeObjection'::text
			  AND s.status_code::text = 'lodged'::text
			  AND  (
		          (aa.lodging_datetime  between to_date(''|| fromDate || '','yyyy-mm-dd')  and to_date(''|| toDate || '','yyyy-mm-dd'))
		           or
		          (aa.change_time  between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd'))
		          )
		        )  
		   )  
		),  --TotLodgedObj

                (
	          SELECT (COUNT(*)) 
		   FROM  application.application aa, 
		   application.service s
		  WHERE  s.application_id::text = aa.id::text 
		  AND s.application_id::text in (select s.application_id 
						 FROM application.service s
						 where s.request_type_code::text = 'systematicRegn'::text
						 ) 
		  AND s.request_type_code::text = 'lodgeObjection'::text
		  AND s.status_code::text = 'cancelled'::text
		  AND  (
		          (aa.lodging_datetime  between to_date(''|| fromDate || '','yyyy-mm-dd')  and to_date(''|| toDate || '','yyyy-mm-dd'))
		           or
		          (aa.change_time  between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd'))
		          )
		), --TotSolvedObj
		
		
		(
		SELECT  
		    count (distinct(aa.id)) 
		    FROM  application.application aa,
			  application.service s, 
			    cadastre.cadastre_object co,
			    administrative.ba_unit_contains_spatial_unit su,
			    administrative.ba_unit bu,
			    transaction.transaction t             
			    WHERE s.application_id = aa.id
			    AND   bu.transaction_id = t.id
                            AND   t.from_service_id = s.id
                            AND   su.spatial_unit_id::text = co.id::text 
			    AND   su.ba_unit_id = bu.id
			    AND   bu.transaction_id = t.id
			    AND   t.from_service_id = s.id
			    AND   s.request_type_code::text = 'systematicRegn'::text
			    AND co.name_lastpart in ( select ss.reference_nr 
		 				      from   source.source ss 
							where ss.type_code='publicNotification'
							AND ss.recordation  between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd')
                                                     )
                 ),  ---TotAppPubDispl


                 (
                  select count(distinct (aa.id))
                   from application.service s, 
                   application.application aa, 
			    cadastre.cadastre_object co,
			    administrative.ba_unit_contains_spatial_unit su,
			    administrative.ba_unit bu,
			    transaction.transaction t             
			    WHERE s.application_id = aa.id
			    AND   bu.transaction_id = t.id
                            AND   t.from_service_id = s.id
                            AND   su.spatial_unit_id::text = co.id::text 
			    AND   su.ba_unit_id = bu.id
			    AND   bu.transaction_id = t.id
			    AND   t.from_service_id = s.id
			    AND   s.request_type_code::text = 'systematicRegn'::text
			    AND co.name_lastpart in ( select ss.reference_nr 
					              from   source.source ss 
					              where ss.type_code='publicNotification'
					              and ss.expiration_date < to_date(''|| toDate ||'','yyyy-mm-dd')
                                                      and   ss.reference_nr in ( select ss.reference_nr from   source.source ss 
										 where ss.type_code='title'
										 and ss.recordation  between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd')
										)   
					            ) 
	         ),  ---TotCertificatesPrepared
                 (select count (distinct(s.id))
                   FROM 
                       application.service s   --,
		   WHERE s.request_type_code::text = 'documentCopy'::text
		   AND s.lodging_datetime between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd')
                   AND s.action_notes is not null )  --TotCertificatesIssued

      

                     
              INTO       TotalAppLod,
                         TotalParcLoaded,
                         TotalRecObj,
                         TotalSolvedObj,
                         TotalAppPDisp,
                         TotalPrepCertificate,
                         TotalIssuedCertificate
               ;        
                Total = 'Total';
                TotalAppLod = TotalAppLod;
                TotalParcLoaded = TotalParcLoaded;
                TotalRecObj = TotalRecObj;
                TotalSolvedObj = TotalSolvedObj;
                TotalAppPDisp = TotalAppPDisp;
                TotalPrepCertificate = TotalPrepCertificate;
                TotalIssuedCertificate = TotalIssuedCertificate;
	  
	  select into recTotalToReturn
                Total::                 varchar, 
                TotalAppLod::  		decimal,	
		TotalParcLoaded::  	varchar,	
		TotalRecObj::  		decimal,	
		TotalSolvedObj::  	decimal,	
		TotalAppPDisp::  	decimal,	
		TotalPrepCertificate:: 	decimal,	
		TotalIssuedCertificate::  decimal;	

	                         
		return next recTotalToReturn;

                
    return;

END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100
  ROWS 1000;
ALTER FUNCTION administrative.getsysregprogress(character varying, character varying, character varying) OWNER TO postgres;


----------------------- FUNCTION administrative.getsysregstatus --------------------------------------------------
CREATE OR REPLACE FUNCTION administrative.getsysregstatus(fromdate character varying, todate character varying, namelastpart character varying)
  RETURNS SETOF record AS
$BODY$
DECLARE 

       	block  			varchar;	
       	appLodgedNoSP 		decimal:=0 ;	
       	appLodgedSP   		decimal:=0 ;	
       	SPnoApp 		decimal:=0 ;	
       	appPendObj		decimal:=0 ;	
       	appIncDoc		decimal:=0 ;	
       	appPDisp		decimal:=0 ;	
       	appCompPDispNoCert	decimal:=0 ;	
       	appCertificate		decimal:=0 ;
       	appPrLand		decimal:=0 ;	
       	appPubLand		decimal:=0 ;	
       	TotApp			decimal:=0 ;	
       	TotSurvPar		decimal:=0 ;	



      
       rec     record;
       sqlSt varchar;
       statusFound boolean;
       recToReturn record;

        -- From Neil's email 9 march 2013
	    -- STATUS REPORT
		--Block	
		--1. Total Number of Applications	
		--2. No of Applications Lodged with Surveyed Parcel	
		--3. No of Applications Lodged no Surveyed Parcel	     
		--4. No of Surveyed Parcels with no application	
		--5. No of Applications with pending Objection	        
		--6. No of Applications with incomplete Documentation	
		--7. No of Applications in Public Display	               
		--8. No of Applications with Completed Public Display but Certificates not Issued	 
		--9. No of Applications with Issued Certificate	
		--10. No of Applications for Private Land	
		--11. No of Applications for Public Land 	
		--12. Total Number of Surveyed Parcels	

    
BEGIN  


    sqlSt:= '';
    
  
 sqlSt:= 'select   co.name_lastpart   as area
                   FROM   application.application aa,     
			  application.service s,
			  cadastre.cadastre_object co,
			  administrative.ba_unit_contains_spatial_unit su,
			  administrative.ba_unit bu,
                          transaction.transaction t             
			    WHERE s.application_id = aa.id
			    AND   bu.transaction_id = t.id
                            AND   t.from_service_id = s.id
                            AND   su.spatial_unit_id::text = co.id::text 
			    AND   su.ba_unit_id = bu.id
			    AND   bu.transaction_id = t.id
			    AND   t.from_service_id = s.id
			    AND   s.request_type_code::text = ''systematicRegn''::text
			    
    ';
    
    if namelastpart != '' then
          sqlSt:= sqlSt|| ' AND compare_strings('''||namelastpart||''', co.name_lastpart) ';
    end if;

    --raise exception '%',sqlSt;
       statusFound = false;

    -- Loop through results
    
    FOR rec in EXECUTE sqlSt loop

    
    select        ( SELECT  
		    count (distinct(aa.id)) 
		    FROM  application.application aa,
			  application.service s,
			  cadastre.cadastre_object co,
			  administrative.ba_unit_contains_spatial_unit su,
			  administrative.ba_unit bu,
                          transaction.transaction t             
			    WHERE s.application_id = aa.id
			    AND   bu.transaction_id = t.id
                            AND   t.from_service_id = s.id
                            AND   su.spatial_unit_id::text = co.id::text 
			    AND   su.ba_unit_id = bu.id
			    AND   bu.transaction_id = t.id
			    AND   t.from_service_id = s.id
			    AND   s.request_type_code::text = 'systematicRegn'::text
			    AND compare_strings(''|| rec.area ||'', co.name_lastpart)
			    AND  (
		          (aa.lodging_datetime  between to_date(''|| fromDate || '','yyyy-mm-dd')  and to_date(''|| toDate || '','yyyy-mm-dd'))
		           or
		          (aa.change_time  between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd'))
		          )
			    ),

		    (SELECT count (distinct(aa.id))
		     FROM application.application aa,
		     application.service s,
			  cadastre.cadastre_object co,
			  administrative.ba_unit_contains_spatial_unit su,
			  administrative.ba_unit bu,
                          transaction.transaction t             
			    WHERE s.application_id = aa.id
			    AND   bu.transaction_id = t.id
                            AND   t.from_service_id = s.id
                            AND   su.spatial_unit_id::text = co.id::text 
			    AND   su.ba_unit_id = bu.id
			    AND   bu.transaction_id = t.id
			    AND   t.from_service_id = s.id
			    AND   s.request_type_code::text = 'systematicRegn'::text
			    AND compare_strings(''|| rec.area ||'', co.name_lastpart)
			 AND  (
		          (aa.lodging_datetime  between to_date(''|| fromDate || '','yyyy-mm-dd')  and to_date(''|| toDate || '','yyyy-mm-dd'))
		           or
		          (aa.change_time  between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd'))
		          )),

	          (SELECT count (*)
	            FROM cadastre.cadastre_object co
			    WHERE co.type_code='parcel'
			    AND   co.id not in (SELECT su.spatial_unit_id FROM administrative.ba_unit_contains_spatial_unit su)
			    AND compare_strings(''|| rec.area ||'', co.name_lastpart)
	          ),

                 (
	          SELECT (COUNT(*)) 
		   FROM  application.application aa,
		     application.service s,
			  cadastre.cadastre_object co,
			  administrative.ba_unit_contains_spatial_unit su,
			  administrative.ba_unit bu,
                          transaction.transaction t             
			    WHERE s.application_id = aa.id
			    AND   bu.transaction_id = t.id
                            AND   t.from_service_id = s.id
                            AND   su.spatial_unit_id::text = co.id::text 
			    AND   su.ba_unit_id = bu.id
			    AND   bu.transaction_id = t.id
			    AND   t.from_service_id = s.id
		  AND s.application_id::text in (select s.application_id 
						 FROM application.service s
						 where s.request_type_code::text = 'systematicRegn'::text
						 ) 
		  AND s.request_type_code::text = 'lodgeObjection'::text
		  AND s.status_code::text != 'cancelled'::text
		  AND compare_strings(''|| rec.area ||'', co.name_lastpart)
		  AND  (
		          (aa.lodging_datetime  between to_date(''|| fromDate || '','yyyy-mm-dd')  and to_date(''|| toDate || '','yyyy-mm-dd'))
		           or
		          (aa.change_time  between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd'))
		          )
		),


		  ( WITH appSys AS 	(SELECT  
		    distinct on (aa.id) aa.id as id
		    FROM  application.application aa,
		     application.service s,
			  cadastre.cadastre_object co,
			  administrative.ba_unit_contains_spatial_unit su,
			  administrative.ba_unit bu,
                          transaction.transaction t             
			    WHERE s.application_id = aa.id
			    AND   bu.transaction_id = t.id
                            AND   t.from_service_id = s.id
                            AND   su.spatial_unit_id::text = co.id::text 
			    AND   su.ba_unit_id = bu.id
			    AND   bu.transaction_id = t.id
			    AND   t.from_service_id = s.id
			    AND   s.request_type_code::text = 'systematicRegn'::text
			    AND compare_strings(''|| rec.area ||'', co.name_lastpart)
			   AND  (
		          (aa.lodging_datetime  between to_date(''|| fromDate || '','yyyy-mm-dd')  and to_date(''|| toDate || '','yyyy-mm-dd'))
		           or
		          (aa.change_time  between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd'))
		          )),
		     sourceSys AS	
		     (
		     SELECT  DISTINCT (sc.id) FROM  application.application_uses_source a_s,
							   source.source sc,
							   appSys app
						where sc.type_code='systematicRegn'
						 and  sc.id = a_s.source_id
						 and a_s.application_id=app.id
						 AND  (
						  (aa.lodging_datetime  between to_date(''|| fromDate || '','yyyy-mm-dd')  and to_date(''|| toDate || '','yyyy-mm-dd'))
						   or
						  (aa.change_time  between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd'))
						  )
						
				)
		      SELECT 	CASE 	WHEN (SELECT (SUM(1) IS NULL) FROM appSys) THEN 0
				WHEN ((SELECT COUNT(*) FROM appSys) - (SELECT COUNT(*) FROM sourceSys) >= 0) THEN (SELECT COUNT(*) FROM appSys) - (SELECT COUNT(*) FROM sourceSys)
				ELSE 0
			END 
				  ),
     
                 (select count(distinct (aa.id))
                   from application.application aa,
		     application.service s,
			  cadastre.cadastre_object co,
			  administrative.ba_unit_contains_spatial_unit su,
			  administrative.ba_unit bu,
                          transaction.transaction t             
			    WHERE s.application_id = aa.id
			    AND   bu.transaction_id = t.id
                            AND   t.from_service_id = s.id
                            AND   su.spatial_unit_id::text = co.id::text 
			    AND   su.ba_unit_id = bu.id
			    AND   bu.transaction_id = t.id
			    AND   t.from_service_id = s.id
			    AND   s.request_type_code::text = 'systematicRegn'::text
			    AND compare_strings(''|| rec.area ||'', co.name_lastpart)
		            AND co.name_lastpart in ( 
		                             select ss.reference_nr from   source.source ss 
					     where ss.type_code='publicNotification'
					     and ss.recordation  between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd')
                                             and ss.expiration_date < to_date(''|| toDate ||'','yyyy-mm-dd')
                                             and ss.reference_nr = ''|| rec.area ||''   
					   )
		 ),

                 ( 
                   select count(distinct (aa.id))
                   from application.application aa,
		     application.service s,
			  cadastre.cadastre_object co,
			  administrative.ba_unit_contains_spatial_unit su,
			  administrative.ba_unit bu,
                          transaction.transaction t             
			    WHERE s.application_id = aa.id
			    AND   bu.transaction_id = t.id
                            AND   t.from_service_id = s.id
                            AND   su.spatial_unit_id::text = co.id::text 
			    AND   su.ba_unit_id = bu.id
			    AND   bu.transaction_id = t.id
			    AND   t.from_service_id = s.id
			    AND   s.request_type_code::text = 'systematicRegn'::text
			    AND compare_strings(''|| rec.area ||'', co.name_lastpart)
		            AND co.name_lastpart in ( 
						      select ss.reference_nr 
						       from   source.source ss 
						       where ss.type_code='publicNotification'
						       and ss.expiration_date < to_date(''|| toDate ||'','yyyy-mm-dd')
						       and   ss.reference_nr not in ( select ss.reference_nr from   source.source ss 
										     where ss.type_code='title'
										     and ss.recordation  between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd')
										     and ss.reference_nr = ''|| rec.area ||''
	 								           )   
		                                     )
                 ),

                 (
                   select count(distinct (aa.id))
                   from application.application aa,
		          application.service s,
			  cadastre.cadastre_object co,
			  administrative.ba_unit_contains_spatial_unit su,
			  administrative.ba_unit bu,
                          transaction.transaction t             
			    WHERE s.application_id = aa.id
			    AND   bu.transaction_id = t.id
                            AND   t.from_service_id = s.id
                            AND   su.spatial_unit_id::text = co.id::text 
			    AND   su.ba_unit_id = bu.id
			    AND   bu.transaction_id = t.id
			    AND   t.from_service_id = s.id
			    AND   s.request_type_code::text = 'systematicRegn'::text
			    AND compare_strings(''|| rec.area ||'', co.name_lastpart)
			    AND co.name_lastpart in ( 
						      select ss.reference_nr 
						      from   source.source ss 
						      where ss.type_code='publicNotification'
						      and ss.expiration_date < to_date(''|| toDate ||'','yyyy-mm-dd')
						      and   ss.reference_nr in ( select ss.reference_nr from   source.source ss 
										   where ss.type_code='title'
										   and ss.recordation  between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd')
										   and ss.reference_nr = ''|| rec.area ||''
									        )   
					            )  
                ),
		 (SELECT count (distinct (aa.id) )
			FROM cadastre.land_use_type lu, 
			cadastre.spatial_value_area sa, 
			party.party pp, administrative.party_for_rrr pr, 
			administrative.rrr rrr, 
			application.application aa,
		          application.service s,
			  cadastre.cadastre_object co,
			  administrative.ba_unit_contains_spatial_unit su,
			  administrative.ba_unit bu,
                          transaction.transaction t             
			    WHERE s.application_id = aa.id
			    AND   bu.transaction_id = t.id
                            AND   t.from_service_id = s.id
                            AND   su.spatial_unit_id::text = co.id::text 
			    AND   su.ba_unit_id = bu.id
			    AND   bu.transaction_id = t.id
			    AND   t.from_service_id = s.id
			    AND   s.request_type_code::text = 'systematicRegn'::text
			    AND compare_strings(''|| rec.area ||'', co.name_lastpart)
			    AND sa.spatial_unit_id::text = co.id::text AND COALESCE(co.land_use_code, 'residential'::character varying)::text = lu.code::text 
			    AND sa.type_code::text = 'officialArea'::text 
			    AND su.spatial_unit_id::text = sa.spatial_unit_id::text 
			    AND s.status_code::text = 'completed'::text 
			    AND pp.id::text = pr.party_id::text AND pr.rrr_id::text = rrr.id::text 
			    AND rrr.ba_unit_id::text = su.ba_unit_id::text
			    AND  (
		            (aa.lodging_datetime  between to_date(''|| fromDate || '','yyyy-mm-dd')  and to_date(''|| toDate || '','yyyy-mm-dd'))
		              or
		             (aa.change_time  between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd'))
		            )
			    AND 
			    (rrr.type_code::text = 'ownership'::text 
			     OR rrr.type_code::text = 'apartment'::text 
			     OR rrr.type_code::text = 'commonOwnership'::text 
			     ) 
		 ),		
		 ( SELECT count (distinct (aa.id) )
			FROM cadastre.land_use_type lu, 
			cadastre.spatial_value_area sa, 
			party.party pp, administrative.party_for_rrr pr, 
			administrative.rrr rrr,
			application.application aa,
		          application.service s,
			  cadastre.cadastre_object co,
			  administrative.ba_unit_contains_spatial_unit su,
			  administrative.ba_unit bu,
                          transaction.transaction t             
			    WHERE s.application_id = aa.id
			    AND   bu.transaction_id = t.id
                            AND   t.from_service_id = s.id
                            AND   su.spatial_unit_id::text = co.id::text 
			    AND   su.ba_unit_id = bu.id
			    AND   bu.transaction_id = t.id
			    AND   t.from_service_id = s.id
			    AND   s.request_type_code::text = 'systematicRegn'::text
			    AND   compare_strings(''|| rec.area ||'', co.name_lastpart)
			    AND   sa.spatial_unit_id::text = co.id::text AND COALESCE(co.land_use_code, 'residential'::character varying)::text = lu.code::text 
			    AND sa.type_code::text = 'officialArea'::text AND su.spatial_unit_id::text = sa.spatial_unit_id::text 
			    AND s.status_code::text = 'completed'::text AND pp.id::text = pr.party_id::text AND pr.rrr_id::text = rrr.id::text 
			    AND rrr.ba_unit_id::text = su.ba_unit_id::text AND rrr.type_code::text = 'stateOwnership'::text AND bu.id::text = su.ba_unit_id::text
			    AND  (
		            (aa.lodging_datetime  between to_date(''|| fromDate || '','yyyy-mm-dd')  and to_date(''|| toDate || '','yyyy-mm-dd'))
		             or
		            (aa.change_time  between to_date(''|| fromDate ||'','yyyy-mm-dd')  and to_date(''|| toDate ||'','yyyy-mm-dd'))
		            ) 
	  	 ), 	
                 (SELECT count (*)
	            FROM cadastre.cadastre_object co
			    WHERE co.type_code='parcel'
			    AND   compare_strings(''|| rec.area ||'', co.name_lastpart)
	         )    
              INTO       TotApp,
                         appLodgedSP,
                         SPnoApp,
                         appPendObj,
                         appIncDoc,
                         appPDisp,
                         appCompPDispNoCert,
                         appCertificate,
                         appPrLand,
                         appPubLand,
                         TotSurvPar
                
              FROM        application.application aa,
		          application.service s,
			  cadastre.cadastre_object co,
			  administrative.ba_unit_contains_spatial_unit su,
			  administrative.ba_unit bu,
                          transaction.transaction t             
			    WHERE s.application_id = aa.id
			    AND   bu.transaction_id = t.id
                            AND   t.from_service_id = s.id
                            AND   su.spatial_unit_id::text = co.id::text 
			    AND   su.ba_unit_id = bu.id
			    AND   bu.transaction_id = t.id
			    AND   t.from_service_id = s.id
			    AND   s.request_type_code::text = 'systematicRegn'::text
			    AND   compare_strings(''|| rec.area ||'', co.name_lastpart)
	  ;        

                block = rec.area;
                TotApp = TotApp;
		appLodgedSP = appLodgedSP;
		SPnoApp = SPnoApp;
                appPendObj = appPendObj;
		appIncDoc = appIncDoc;
		appPDisp = appPDisp;
		appCompPDispNoCert = appCompPDispNoCert;
		appCertificate = appCertificate;
		appPrLand = appPrLand;
		appPubLand = appPubLand;
		TotSurvPar = TotSurvPar;
		appLodgedNoSP = TotApp-appLodgedSP;
		


	  
	  select into recToReturn
	       	block::			varchar,
		TotApp::  		decimal,
		appLodgedSP::  		decimal,
		SPnoApp::  		decimal,
		appPendObj::  		decimal,
		appIncDoc::  		decimal,
		appPDisp::  		decimal,
		appCompPDispNoCert::  	decimal,
		appCertificate::  	decimal,
		appPrLand::  		decimal,
		appPubLand::  		decimal,
		TotSurvPar::  		decimal,
		appLodgedNoSP::  	decimal;

		                         
          return next recToReturn;
          statusFound = true;
          
    end loop;
   
    if (not statusFound) then
         block = 'none';
                
        select into recToReturn
	       	block::			varchar,
		TotApp::  		decimal,
		appLodgedSP::  		decimal,
		SPnoApp::  		decimal,
		appPendObj::  		decimal,
		appIncDoc::  		decimal,
		appPDisp::  		decimal,
		appCompPDispNoCert::  	decimal,
		appCertificate::  	decimal,
		appPrLand::  		decimal,
		appPubLand::  		decimal,
		TotSurvPar::  		decimal,
		appLodgedNoSP::  	decimal;

		                         
          return next recToReturn;

    end if;
    return;
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100
  ROWS 1000;
ALTER FUNCTION administrative.getsysregstatus(character varying, character varying, character varying) OWNER TO postgres;



