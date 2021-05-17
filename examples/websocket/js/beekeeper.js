/*

    Beekeeper client (JSON-RPC over MQTT)

    Copyright 2015-2021 José Micó

    For protocol references see: 
    - https://mqtt.org/mqtt-specification
    - https://www.jsonrpc.org/specification

    This uses the MQTT.js library:
    - https://github.com/mqttjs/MQTT.js

    var bkpr = new BeekeeperClient;

    bkpr.connect({
        url:       "ws://localhost:8000/mqtt",
        username:  "guest",
        password:  "guest",
        on_connect: function() {...}
    });

    bkpr.send_notification({
        method: "test.foo",
        params: { foo: "bar" }
    });

    bkpr.call_remote_method({
        method:    "test.bar",
        params:     { foo: "baz" },
        on_success: function(result) {...},
        on_error:   function(error) {...}
    });

    bkpr.accept_notifications({
        method:    "test.foo.*",
        on_receive: function(params) {...}
    });

    bkpr.accept_remote_calls({
        method:    "test.bar",
        on_receive: function(params) {...}
    });
*/

function BeekeeperClient () { return {

    mqtt: null,
    host: null,
    client_id: null,
    response_topic: null,
    request_seq: 1,
    subscr_seq: 1,
    pending_req: {},
    subscr_cb: {},
    subscr_re: {},

   _debug: function () {},
    debug: function(enabled) {
        if (enabled) {
            this._debug = function (msg) { console.log("BeekeeperClient: " + msg) };
        }
        else {
            this._debug = function () {};
        }
    },

    connect: function(args) {

        var This = this;

        if ('debug' in args) this.debug(args.debug);

        this._debug("Connecting to MQTT broker at " + args.url);

        var id = ''; for(;id.length < 16;) id += (Math.random() * 36 | 0).toString(36);
        this.client_id = id;

        // It is possible to iterate over a list of servers specifying:
        // url: [{ host: 'localhost', port: 1883 }, ... ]

        // Connect to MQTT broker using websockets
        this.mqtt = mqtt.connect( args.url, {
            username: args.username || 'guest',
            password: args.password || 'guest',
            clientId: this.client_id,
            protocolVersion: 5,
            clean: true,
            keepalive: 60,
            reconnectPeriod: 1000,
            connectTimeout: 30 * 1000
        });

        this.mqtt.on('connect', function (connack) {
            This.host = This.mqtt.options.host;
            This._debug("Connected to MQTT broker at " + This.host);
            This._create_response_topic();
            if (args.on_connect) args.on_connect(connack.properties);
        });

        this.mqtt.on('reconnect', function () {
            // Emitted when a reconnect starts
            This._debug("Reconnecting...");
        });

        this.mqtt.on('close', function () {
            // Emitted after a disconnection
            This._debug("Disconnected");
        });

        this.mqtt.on('disconnect', function (packet) {
            // Emitted after receiving disconnect packet from broker
            This._debug("Disconnected by broker");
        });

        this.mqtt.on('offline', function () {
            // Emitted when the client goes offline
            This._debug("Client offline");
        });

        this.mqtt.on('error', function (error) {
            // Emitted when the client cannot connect
            This._debug(error);
        });

        this.mqtt.on('message', function (topic, message, packet) {

            var jsonrpc;
            try { jsonrpc = JSON.parse( message.toString() ) }
            catch (e) { throw "Received invalid JSON: " + e }
            This._debug("Got  << " + message);

            var subscr_id = packet.properties.subscriptionIdentifier;
            var subscr_cb = This.subscr_cb[subscr_id];

            subscr_cb(jsonrpc, packet.properties);
        });
    },

    send_notification: function(args) {

        if (!this.mqtt.connected) throw "Not connected to MQTT broker";

        var json = JSON.stringify({
            jsonrpc: "2.0",
            method: args.method,
            params: args.params
        });

        this._debug("Sent >> " + json);

        this.mqtt.publish(
            'msg/' + args.method.replace(/\./g,'/'),
            json,
            {}
        );
    },

    accept_notifications: function (args) {

        if (!this.mqtt.connected) throw "Not connected to MQTT broker";

        var subscr_id = this.subscr_seq++;
        var on_receive = args.on_receive;

        this.subscr_cb[subscr_id] = function(jsonrpc, packet_prop) {

            // Incoming notification

            try { on_receive( jsonrpc.params, packet_prop ) }
            catch(e) { This._debug("Uncaught exception into on_receive callback of " + jsonrpc.method + ": " + e) }
        };

        this.subscr_re[subscr_id] = new RegExp('^' + args.method.replace(/\./g,'\\.').replace(/\*/g,'.+') + '$');

        // Private notifications are received on response_topic subscription
        if (args.private) return;

        var topic = 'msg/backend/' + args.method.replace(/\./g,'/').replace(/\*/g,'#');

        this.mqtt.subscribe(
            topic,
            { properties: { subscriptionIdentifier: subscr_id }},
            function (err, granted) {
                if (err) throw "Failed to subscribe to " + topic + ": " + err;
            }
        );
    },

    call_remote_method: function(args) {

        if (!this.mqtt.connected) throw "Not connected to MQTT broker";

        var req_id = this.request_seq++;

        var json = JSON.stringify({
            jsonrpc: "2.0",
            method: args.method,
            params: args.params,
            id:     req_id
        });

        var QUEUE_LANES = 2;
        var topic = 'req/backend-' + Math.floor( Math.random() * QUEUE_LANES + 1 );
        var fwd_to = 'req/backend/' + args.method.replace(/\.[\w-]+$/,'').replace(/\./g,'/');

        this.mqtt.publish(
            topic,
            json,
            { properties: {
                responseTopic: this.response_topic,
                userProperties: { fwd_to: fwd_to }
            }}
        );

        this._debug("Sent >> " + json);

        this.pending_req[req_id] = {
            method:     args.method,
            on_success: args.on_success,
            on_error:   args.on_error,
            timeout:    null
        };

        var This = this;

        this.pending_req[req_id].timeout = setTimeout( function() {
            delete This.pending_req[req_id];
            if (args.on_error) {
                try { args.on_error({ code: -32603, message: "Remote method call timed out" }) }
                catch(e) { This._debug("Uncaught exception into on_error callback of " + args.method + ": " + e) }
            }
            else {
                This._debug("Call to " + args.method + " timed out");
            }
        }, (args.timeout || 30) * 1000);
    },

    _create_response_topic: function() {

        var response_topic = 'priv/' + this.client_id;
        this.response_topic = response_topic;

        var subscr_id = this.subscr_seq++;
        var This = this;

        this.subscr_cb[subscr_id] = function(jsonrpc, packet_prop) {

            if (!jsonrpc.id) {

                // Incoming private notification

                var on_receive;
                for (var subscr_id in This.subscr_re) {
                    if (jsonrpc.method.match( This.subscr_re[subscr_id] )) {
                        on_receive = This.subscr_cb[subscr_id];
                        break;
                    }
                }

                if (on_receive) {
                    try { on_receive( jsonrpc.params, packet_prop ) }
                    catch(e) { This._debug("Uncaught exception into on_receive callback of " + jsonrpc.method + ": " + e) }
                }
                else {
                    This._debug("Received unhandled private notification " + jsonrpc.method);
                }

                return;
            }

            // Incoming remote call response

            var resp = jsonrpc;
            var req = This.pending_req[resp.id];
            delete This.pending_req[resp.id];
            if (!req) return;

            clearTimeout(req.timeout);

            if ('result' in resp) {
                if (req.on_success) {
                    try { req.on_success( resp.result, packet_prop ) }
                    catch(e) { This._debug("Uncaught exception into on_success callback of " + req.method + ": " + e) }
                }
            }
            else {
                if (req.on_error) {
                    try { req.on_error( resp.error, packet_prop ) }
                    catch(e) { This._debug("Uncaught exception into on_error callback of " + req.method + ": " + e) }
                }
                else {
                    This._debug("Error response from " + req.method + " call: " + resp.error.message);
                }
            }
        };

        this.mqtt.subscribe(
            response_topic,
            { properties: { subscriptionIdentifier: subscr_id }},
            function (err, granted) {
                if (err) throw "Failed to subscribe to " + response_topic + ": " + err;
            }
        );
    },

    accept_remote_calls: function(args) {

        // This is included for reference, but note that frontend clients 
        // should *not* be allowed to even connect to the backend broker

        if (!this.mqtt.connected) throw "Not connected to MQTT broker";

        var subscr_id = this.subscr_seq++;
        var on_receive = args.on_receive;
        var This = this;

        this.subscr_cb[subscr_id] = function(jsonrpc, packet_prop) {

            // Incoming remote request

            var json;

            try {
                var result = on_receive( jsonrpc.params, packet_prop );
                json = JSON.stringify({
                    jsonrpc: "2.0",
                    result: result,
                    id: req.id
                });
            }
            catch (e) {
                json = JSON.stringify({
                    jsonrpc: "2.0",
                    error: { code: -32603, message: e.message },
                    id: req.id
                });
            }

            This.mqtt.publish(
                packet_prop.responseTopic,
                json,
                {}
            );

            This._debug("Sent >> " + json);
        };

        var topic = '$share/BKPR/req/backend/' + args.method.replace(/\./g,'/');

        this.mqtt.subscribe(
            topic,
            { properties: { subscriptionIdentifier: subscr_id }},
            function (err, granted) {
                if (err) throw "Failed to subscribe to " + topic + ": " + err;
            }
        );
    },
}};
