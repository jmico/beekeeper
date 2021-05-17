## WebSocket example

This example shows how to use services from browsers using WebSockets.


To run this example start the worker pool:
```
cd beekeper/examples/websocket
source setup.sh
./run.sh
```
Then open `client.html` in a browser, or use the command line client:
```
./client.pl
```
You can check the pool status with `bkpr-top` or watch the stream of exceptions that
this example generates with `bkpr-log -f`. When done, stop the worker pool with:
```
./run.sh stop
```
---

### HiveMQ setup

This example uses the internal ToyBroker to allow being run out of the box, but 
to use actual WebSockets from `client.html` a real broker like HiveMQ is required 
(`client.pl` works fine with ToyBroker though).

To run this example on a fresh install of HiveMQ just set `use_toybroker` to false in
config file `pool.config.json`. Also ensure that `host` addresses in `bus.config.json` 
and `config.js` match HiveMQ one. This is a sample `config.xml` for HiveMQ:

```
<?xml version="1.0"?>
<hivemq>

    <listeners>
        <tcp-listener>
            <port>1883</port>
            <bind-address>0.0.0.0</bind-address>
        </tcp-listener>
        <websocket-listener>
            <port>8000</port>
            <bind-address>0.0.0.0</bind-address>
            <path>/mqtt</path>
            <subprotocols>
                <subprotocol>mqttv3.1</subprotocol>
                <subprotocol>mqtt</subprotocol>
            </subprotocols>
            <allow-extensions>true</allow-extensions>
        </websocket-listener>
    </listeners>

    <mqtt>
        <queued-messages>
            <!-- Maximum number of messages per client that will be queued on the broker -->
            <max-queue-size>10000</max-queue-size>
        </queued-messages>
        <receive-maximum>
            <!-- Maximum number of unacknowledged messages that each client can send -->
            <server-receive-maximum>10000</server-receive-maximum>
        </receive-maximum>
    </mqtt>

</hivemq>
```
---

This example uses the MQTT.js library Copyright 2015-2021 MQTT.js contributors 
under MIT License (<https://github.com/mqttjs/MQTT.js>).
