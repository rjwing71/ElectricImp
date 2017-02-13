//line 1 "agent.nut"
// Utility Libraries
#require "Rocky.class.nut:1.2.3"
#require "bullwinkle.class.nut:2.3.2"

// Class that receives and handles data sent from device SmartFridgeApp
//line 1 "SmartFrigDataManager.class.nut"
/***************************************************************************************
 * SmartFrigDataManager Class:
 *      Handle incoming device readings and events
 *      Set callback handlers for events and streaming data
 *      Average temperature and humidity readings
 *
 * Dependencies
 *      Bullwinle (passed into the constructor)
 **************************************************************************************/
class SmartFrigDataManager {

    static DEBUG_LOGGING = true;

    // Event types (these should match device side event types in SmartFrigDataManager)
    static EVENT_TYPE_TEMP_ALERT = "temperaure alert";
    static EVENT_TYPE_HUMID_ALERT = "humidity alert";
    static EVENT_TYPE_DOOR_ALERT = "door alert";
    static EVENT_TYPE_DOOR_STATUS = "door status";

    _streamReadingsHandler = null;
    _doorOpenAlertHandler = null;
    _tempAlertHandler = null;
    _humidAlertHandler = null;

    // Class instances
    _bull = null;

    /***************************************************************************************
     * Constructor
     * Returns: null
     * Parameters:
     *      bullwinkle : instance - of Bullwinkle class
     **************************************************************************************/
    constructor(bullwinkle) {
        _bull = bullwinkle;
        openListeners();
    }

     /***************************************************************************************
     * openListeners
     * Returns: null
     * Parameters: none
     **************************************************************************************/
    function openListeners() {
        _bull.on("update", _readingsHandler.bindenv(this));
    }

    /***************************************************************************************
     * setStreamReadingsHandler
     * Returns: null
     * Parameters:
     *      cb : function - called when new reading received
     **************************************************************************************/
    function setStreamReadingsHandler(cb) {
        _streamReadingsHandler = cb;
    }

    /***************************************************************************************
     * setDoorOpenAlertHandler
     * Returns: null
     * Parameters:
     *      cb : function - called when door open alert triggered
     **************************************************************************************/
    function setDoorOpenAlertHandler(cb) {
        _doorOpenAlertHandler = cb;
    }

    /***************************************************************************************
     * setTempAlertHandler
     * Returns: null
     * Parameters:
     *      cb : function - called when temperature alert triggerd
     **************************************************************************************/
    function setTempAlertHandler(cb) {
        _tempAlertHandler = cb;
    }

    /***************************************************************************************
     * setHumidAlertHandler
     * Returns: null
     * Parameters:
     *      cb : function - called when humidity alert triggerd
     **************************************************************************************/
    function setHumidAlertHandler(cb) {
        _humidAlertHandler = cb;
    }

    // ------------------------- PRIVATE FUNCTIONS ------------------------------------------

    /***************************************************************************************
     * _getAverage
     * Returns: null
     * Parameters:
     *      readings : table of readings
     *      type : key from the readings table for the readings to average
     *      numReadings: number of readings in the table
     **************************************************************************************/
    function _getAverage(readings, type, numReadings) {
        if (numReadings == 1) {
            return readings[0][type];
        } else {
            local total = readings.reduce(function(prev, current) {
                    return (!(type in prev)) ? prev + current[type] : prev[type] + current[type];
                })
            return total / numReadings;
        }
    }

    /***************************************************************************************
     * _readingsHandler
     * Returns: null
     * Parameters:
     *      message : table - message received from bullwinkle listener
     *      reply: function that sends a reply to bullwinle message sender
     **************************************************************************************/
    function _readingsHandler(message, reply) {
        local data = message.data;
        local streamingData = { "ts" : time() };
        local numReadings = data.readings.len();

        // send ack to device (device erases this set of readings/events when ack received)
        reply("OK");

        if (DEBUG_LOGGING) {
            server.log("in readings handler")
            server.log(http.jsonencode(data.readings));
            server.log(http.jsonencode(data.doorStatus));
            server.log(http.jsonencode(data.events));
            server.log("Current time: " + time())
        }

        if ("readings" in data && numReadings > 0) {

            // Update streaming data table with temperature and humidity averages
            streamingData.temperature <- _getAverage(data.readings, "temperature", numReadings);
            streamingData.humidity <- _getAverage(data.readings, "humidity", numReadings);
        }

        if ("doorStatus" in data) {
            // Update streaming data table
            streamingData.door <- data.doorStatus.currentStatus;
        }

        // send streaming data to handler
        _streamReadingsHandler(streamingData);

        if ("events" in data && data.events.len() > 0) {
            // handle events
            foreach (event in data.events) {
                switch (event.type) {
                    case EVENT_TYPE_TEMP_ALERT :
                        _tempAlertHandler(event);
                        break;
                    case EVENT_TYPE_HUMID_ALERT :
                        _humidAlertHandler(event);
                        break;
                    case EVENT_TYPE_DOOR_ALERT :
                        _doorOpenAlertHandler(event);
                        break;
                    case EVENT_TYPE_DOOR_STATUS :
                        break;
                }
            }
        }
    }

}
//line 11 "agent.nut"


/***************************************************************************************
 * Application Class:
 *      Sends data and alerts to Salesforce
 *
 * Dependencies
 *      Bullwinkle Library
 *      Rocky Library
 *      Salesforce Library, SalesforceOAuth2 Class
 *      SmartFrigDataManager Class
 **************************************************************************************/
class Application {

    static DOOR_ALERT = "Refrigerator Door Open";
    static TEMP_ALERT = "Temperature Over Threshold";
    static HUMID_ALERT = "Humidity Over Threshold";

    _dm = null;
    _deviceID = null;
    _herokuURL = null;

    /***************************************************************************************
     * Constructor
     * Returns: null
     * Parameters:
     *      herokuURL : string - Your Heroku APP URL (URL of created in Heroku Application)
     **************************************************************************************/
    constructor(herokuURL) {
    	_herokuURL = herokuURL;
        _deviceID = imp.configparams.deviceid.tostring();
        initializeClasses();
        setDataMngrHandlers();
    }

    /***************************************************************************************
     * initializeClasses
     * Returns: null
     * Parameters: null
     **************************************************************************************/
    function initializeClasses() {
        local _bull = Bullwinkle();

        _dm = SmartFrigDataManager(_bull);
    }

    /***************************************************************************************
     * setDataMngrHandlers
     * Returns: null
     * Parameters: none
     **************************************************************************************/
    function setDataMngrHandlers() {
        _dm.setDoorOpenAlertHandler(doorOpenHandler.bindenv(this));
        _dm.setStreamReadingsHandler(streamReadingsHandler.bindenv(this));
        _dm.setTempAlertHandler(tempAlertHandler.bindenv(this));
        _dm.setHumidAlertHandler(humidAlertHandler.bindenv(this));
    }

    /***************************************************************************************
     * updateRecord
     * Returns: null
     * Parameters:
     *      data : table - temperature, humidity, door status and ts
     *      cb(optional) : function - callback executed when http request completes
     **************************************************************************************/
    function updateRecord(data, cb = null) {
        local body = {};

        // add salesforce custom object postfix to data keys
        foreach(k, v in data) {
            if (k == "ts") { v = formatTimestamp(v); }
            body[k + "__c"] <- v;
        }

        _request("POST", "sobjects/Update", http.jsonencode(body), cb);
    }

    /***************************************************************************************
     * openCase
     * Returns: null
     * Parameters:
     *      subject : string - type of alert, will be the subject of the case
     *      description : string - description of event
     *      cb(optional) : function - callback executed when http request completes
     **************************************************************************************/
    function openCase(subject, description, cb = null) {
        local data = {
            "Subject": subject,
            "Description": description,
            "Related_Fridge__r" : {"DeviceId__c": _deviceID}
        };

        _request("POST", "sobjects/Case", http.jsonencode(data), cb);
    }

    /***************************************************************************************
     * streamReadingsHandler
     * Returns: null
     * Parameters:
     *      reading : table - temperature, humidity and door status
     **************************************************************************************/
    function streamReadingsHandler(reading) {
        server.log(http.jsonencode(reading));
        updateRecord(reading, updateRecordResHandler);
    }

    /***************************************************************************************
     * doorOpenHandler
     * Returns: null
     * Parameters:
     *      event: table with event details
     **************************************************************************************/
    function doorOpenHandler(event) {
        // { "description": "door has been open for 33 seconds", "type": "door alert", "ts": 1478110044 }
        local description = format("Refrigerator with id %s %s.", _deviceID, event.description);
        server.log(DOOR_ALERT + ": " + description);
        openCase(DOOR_ALERT, description, caseResponseHandler);
    }

    /***************************************************************************************
     * tempAlertHandler
     * Returns: null
     * Parameters:
     *      event: table with event details
     **************************************************************************************/
    function tempAlertHandler(event) {
        local description = format("Refrigerator with id %s %s. Current temperature is %s°C.", _deviceID, event.description, event.latestReading.tostring());
        server.log(TEMP_ALERT + ": " + description);
        openCase(TEMP_ALERT, description, caseResponseHandler);
    }

    /***************************************************************************************
     * humidAlertHandler
     * Returns: null
     * Parameters:
     *      event: table with event details
     **************************************************************************************/
    function humidAlertHandler(event) {
        local description = format("Refrigerator with id %s %s. Current humidity is %s%s.", _deviceID, event.description, event.latestReading.tostring(), "%");
        server.log(HUMID_ALERT + ": " + description);
        openCase(HUMID_ALERT, description, caseResponseHandler);
    }

    /***************************************************************************************
     * caseResponseHandler
     * Returns: null
     * Parameters:
     *      err : string/null - error message
     *      data : table - response table
     **************************************************************************************/
    function caseResponseHandler(err, data) {
        if (err) {
            server.error(http.jsonencode(err));
            return;
        }

        server.log("Created case with id: " + data.id);
    }

    /***************************************************************************************
     * updateRecordResHandler
     * Returns: null
     * Parameters:
     *      err : string/null - error message
     *      respData : table - response table
     **************************************************************************************/
    function updateRecordResHandler(err, respData) {
        if (err) {
            server.error(http.jsonencode(err));
            return;
        }

        // Log a message for creating/updating a record
        if ("success" in respData) {
            server.log("Record created: " + respData.success);
        }
    }

    /***************************************************************************************
     * formatTimestamp
     * Returns: time formatted as "2015-12-03T00:54:51Z"
     * Parameters:
     *      ts (optional) : integer - epoch timestamp
     **************************************************************************************/
    function formatTimestamp(ts = null) {
        local d = ts ? date(ts) : date();
        return format("%04d-%02d-%02dT%02d:%02d:%02dZ", d.year, d.month+1, d.day, d.hour, d.min, d.sec);
    }

    /***************************************************************************************
     * formatTimestamp
     * Returns: time formatted as "2015-12-03T00:54:51Z"
     * Parameters:
     *      verb: string - HTTP request method (GET, POST, PUT, DELETE, etc)
     *      service(optional): string - service part in the request address
     *      body(optional): string - data that will be add to the HTTP request body
     *      cb(optional): function - callback executed when http request completes
     **************************************************************************************/
    function _request(verb, service = null, body = null, cb = null) {
        if (body == null) body = "";
        local headers = {
            "content-type": "application/json",
            "accept": "application/json"
        }
        local myURL = service == null ? _herokuURL : _herokuURL + service;
        local req = http.request("POST", myURL, headers, body);
        if (cb != null) {
            req.sendasync( function(resp) {
                local data = {};
                try { 
                    data = http.jsondecode(resp.body);
                } catch (ex) { 
                    data = { }; 
                }
                if (resp.statuscode >= 200 && resp.statuscode < 300) {
                    cb(null, data);
                } else {
                    cb(data, null);
                }
            }.bindenv(this));
        } else {
            local resp = req.sendsync();
            server.log("Response: " + resp.statuscode + ", body=" + resp.body);
        }
    }
}


// RUNTIME
// ---------------------------------------------------------------------------------

// HEROKU APP URL
// ----------------------------------------------------------
local herokuURL = "<YOUR HEROKU URL HERE>";

// Start Application
Application(herokuURL);