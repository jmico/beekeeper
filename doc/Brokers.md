## Supported brokers

Beekeeper will run on any compliant MQTT 5 broker (version 5 is needed because of the use of 
shared topics). But being shared topics a relatively recent feature, brokers stoll have bugs
or shortcomings in its implementation.

- **Mosquitto** (as of 2.0.10) is a mature product and works fine for the most part.

- **ToyBroker** works perfectly but does not scale and does not provides a WebSocket frontend.
  But it is very handy for development or running tests.

- **HiveMQ CE** (as of 2021.1) works perfectly, but (as at this writing) has a bug which causes
   messages on shared topics to be lost sometimes.

- **VerneMQ** (as of 1.12.2) works perfectly, but fails to resend unacknowledged messages on 
  client disconnection.

Beekeeper, being broker agnostic and following the MQTT specification as much as possible,
allows to switch brokers at any time or mix them in different roles.

See a full list of MQTT brokers at https://en.wikipedia.org/wiki/Comparison_of_MQTT_implementations


## Security notes

- Enable TLS on any production system.

- Keeping a broker open for public writes is fairly risky: it will face unfriendly traffic and DOS attempts. 
  Unless it is required to handle requests from frontend it is better to forbid any public write at all.

- Backend and frontend brokers should be run on isolated systems. Workers or routers should never run on 
  same system as the frontend broker one.

- Untrusted users should not be able to write on resources which other users read. A topic open to the 
  internet should be read-only, otherwise a malicious actor can inject malformed or false data to another 
  users. Frontend topics `msg.frontend.*` must be read-only for end users.

- Untrusted users should not be able to read on resources which other users write. A topic open to the 
  internet should be write-only, otherwise a malicious actor can disrupt a service consuming from the topic,
  as data sent to it will never reach its intended destination. It also allow to easily obtain data submitted
  by other users, which could be a security problem. Frontend queues `req.backend-n` must be write-only for 
  end users.

- Broker must be configured to discard unconsumed messages. Otherwise it may eventually run out of memory.

- Being allowed to connect to the frontend broker does not automatically allows a client unrestricted 
  access to the application, it must additionally be authorized by the application itself. This is done
  in order to allow users to interact with the system even before being logged in (allowing unregistered
  users to do a checkout for example). But if this is not needed, access to the frontend broker itself 
  can be restricted at discretion.

- Remote users should never ever be allowed to connect to the backend broker.


### Mosquitto setup

To setup a Mosquitto instance for **backend** role:

Create `/etc/mosquitto/conf.d/beekeeper.backend.conf`
```
pid_file /run/mosquitto/mosquitto.backend.pid
log_dest file /var/log/mosquitto/mosquitto.backend.log

per_listener_settings true

# Backend
listener 1883 0.0.0.0
protocol mqtt
max_qos 1
persistence false
persistent_client_expiration 1m
max_queued_messages 10000
allow_anonymous false
acl_file /etc/mosquitto/conf.d/beekeeper.backend.acl
password_file /etc/mosquitto/conf.d/beekeeper.backend.users

```
Create `/etc/mosquitto/conf.d/beekeeper.backend.acl`
```
user backend

topic   readwrite   req/#
topic   readwrite   msg/#
topic   readwrite   res/#
topic   readwrite   log/#
topic   readwrite   priv/#
```
And finally create a user running the following command:
```
mosquitto_passwd -c -b /etc/mosquitto/conf.d/beekeeper.backend.users  backend   def456
```
The broker instance can be started with:
```
mosquitto -c /etc/mosquitto/conf.d/beekeeper.backend.conf
```

To setup a Mosquitto instance for **frontend** role:

Create `/etc/mosquitto/conf.d/beekeeper.frontend.conf`
```
pid_file /run/mosquitto/mosquitto.frontend.pid
log_dest file /var/log/mosquitto/mosquitto.frontend.log

per_listener_settings true

# Frontend tcp
listener 8001 0.0.0.0
protocol mqtt
max_qos 1
persistence false
persistent_client_expiration 1m
max_queued_messages 100
allow_anonymous false
acl_file /etc/mosquitto/conf.d/beekeeper.frontend.acl
password_file /etc/mosquitto/conf.d/beekeeper.users

# Frontend WebSocket
listener 8000 0.0.0.0
protocol websockets
max_qos 1
persistence false
persistent_client_expiration 1m
max_queued_messages 100
allow_anonymous false
acl_file /etc/mosquitto/conf.d/beekeeper.frontend.acl
password_file /etc/mosquitto/conf.d/beekeeper.frontend.users

```
Create `/etc/mosquitto/conf.d/beekeeper.frontend.acl`
```
pattern  read   priv/%c

user frontend

topic   read    msg/#
topic   write   req/#

user router

topic   write   msg/#
topic   read    req/#
topic   write   priv/#
```
And finally create users running the following commands:
```
mosquitto_passwd -c -b /etc/mosquitto/conf.d/beekeeper.frontend.users  frontend  abc123
mosquitto_passwd    -b /etc/mosquitto/conf.d/beekeeper.frontend.users  backend   def456
mosquitto_passwd    -b /etc/mosquitto/conf.d/beekeeper.frontend.users  router    ghi789
```
The broker instance can be started with:
```
mosquitto -c /etc/mosquitto/conf.d/beekeeper.frontend.conf
```
---


### HiveMQ setup

To setup an unsecure basic HiveMQ instance suitable to running examples edit `conf/config.xml`:

```
<?xml version="1.0"?>
<hivemq>

    <listeners>
        <tcp-listener>
            <port>1883</port>
            <bind-address>0.0.0.0</bind-address>
        </tcp-listener>
        <tcp-listener>
            <port>8001</port>
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
