## Supported brokers

Beekeeper will run on any compliant MQTT 5 broker (version 5 is needed because of the use of 
shared topics). But being shared topics a relatively recent feature, brokers still have bugs
or shortcomings in its implementation.

- **ToyBroker** is a simple pure Perl MQTT 5 broker included with this distribution. It is 
  suitable for development and running tests, but it does not scale, does not provide any kind 
  of security, and does not provides a WebSocket frontend. So it cannot be used on production.

- **[Eclipse Mosquitto](https://mosquitto.org/)** (as of 2.0.11) works fine. It is fast, easy to
  configure and is battle tested. It is single threaded (each instance uses only one CPU core)
  so it scales worse than other brokers. As most brokers it does not resend unacknowledged
  messages after abrupt disconnections, leading to a potential loss of requests on power loss
  for example (test `int_signal.t` fails).

- **[HiveMQ Community Edition](https://www.hivemq.com/developers/community/)** (as of 2021.1)
  works fine. It handles correctly abrupt disconnections, but it does a poor job at load
  balancing requests: it sends small batches to a single worker instead of doing a proper 
  round-robin among idle workers (test `recursion.t` fails).

- **[VerneMQ](https://vernemq.com/)** (as of 1.12.2) works fine. As Mosquitto, it fails to resend
  unacknowledged messages after abrupt disconnections (test `int_signal.t` fails).

Beekeeper, being broker agnostic and following the MQTT specification strictly, allows to switch
brokers at any time or mix them in different roles.

See a full list of MQTT brokers at https://en.wikipedia.org/wiki/Comparison_of_MQTT_implementations


## Security notes

- Enable TLS on any production system.

- Keeping a broker open for public writes is fairly risky: it will face unfriendly traffic and DOS attempts. 
  Unless it is required to handle requests from frontend it is better to forbid any public write at all.

- Backend and frontend brokers should be run on isolated systems. Workers or routers should never run on 
  same system as the frontend broker one.

- Untrusted users should not be able to write on resources which other users read. A topic open to the 
  internet should be read-only, otherwise a malicious actor can inject malformed or false data to another 
  users. Frontend topics `msg/*` must be read-only for end users.

- Untrusted users should not be able to read on resources which other users write. A topic open to the 
  internet should be write-only, otherwise a malicious actor can disrupt a service consuming from the topic,
  as data sent to it will never reach its intended destination. It also allow to easily obtain data submitted
  by other users, which could be a security problem. Frontend topics `req/*` must be write-only for 
  end users.

- Broker must be configured to discard persistent messages if possible, as Beekeeper does not rely on them.

- Being allowed to connect to the frontend broker does not automatically allows a client unrestricted 
  access to a Beekeeper application, it must additionally be authorized by the application itself. This is
  done in order to allow users to interact with the system even before being logged in (allowing unregistered
  users to do a checkout for example). But if this is not needed, connections to the frontend broker 
  can be restricted using any access control mechanism provided by the broker.

- The authorization system implemented in workers is advisory only. It makes harder to execute a task
  with wrong permissions by mistake, but if a worker has write access to the backend bus it can easily 
  override these restrictions and make any arbitrary request.

- Remote users should never ever be allowed to connect directly to the backend broker.

---

### Mosquitto setup

To setup a Mosquitto instance for **backend** role:

Create `/etc/mosquitto/conf.d/beekeeper.backend.conf`
```
pid_file /run/mosquitto/mosquitto.backend.pid
log_dest file /var/log/mosquitto/mosquitto.backend.log

per_listener_settings true
max_queued_messages 10000
set_tcp_nodelay true

# Backend
listener 1883 0.0.0.0
protocol mqtt
max_qos 1
persistence false
retain_available false
persistent_client_expiration 1h
allow_anonymous false
acl_file /etc/mosquitto/conf.d/beekeeper.backend.acl
password_file /etc/mosquitto/conf.d/beekeeper.backend.users
```
Create `/etc/mosquitto/conf.d/beekeeper.backend.acl`
```
pattern   read   priv/%c/#

user backend

topic   readwrite   req/#
topic   readwrite   msg/#
topic   readwrite   res/#
topic   readwrite   log/#
topic   write       priv/#
```
Create a 'backend' broker user running the following command:
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
max_queued_messages 1
max_packet_size 131072
set_tcp_nodelay true

# Frontend tcp
listener 8001 0.0.0.0
protocol mqtt
max_qos 1
persistence false
retain_available false
persistent_client_expiration 1h
allow_anonymous false
acl_file /etc/mosquitto/conf.d/beekeeper.frontend.acl
password_file /etc/mosquitto/conf.d/beekeeper.users

# Frontend WebSocket
listener 8000 0.0.0.0
protocol websockets
max_qos 1
persistence false
retain_available false
persistent_client_expiration 1h
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
Create broker users running the following commands:
```
mosquitto_passwd -c -b /etc/mosquitto/conf.d/beekeeper.frontend.users  frontend  abc123
mosquitto_passwd    -b /etc/mosquitto/conf.d/beekeeper.frontend.users  router    ghi789
```
The broker instance can be started with:
```
mosquitto -c /etc/mosquitto/conf.d/beekeeper.frontend.conf
```
In order to scale up multiple broker instances may be needed. Check
[this tutorial](https://frederik.lindenaar.nl/2019/05/30/multiple-mosquitto-instances-on-debian-with-systemd.html)
about how to run multiple Mosquitto instances in a single system.

---

### HiveMQ setup

To setup an insecure basic HiveMQ instance suitable to running examples edit `conf/config.xml`:

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
