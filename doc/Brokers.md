## Supported brokers

Beekeeper will run on any compliant MQTT 5 broker (version 5 is needed because of the use of 
shared topics). But being shared topics a relatively recent feature, brokers still have bugs
or shortcomings in its implementation.

- **ToyBroker** is a simple pure Perl MQTT 5 broker included with this distribution. It is 
  suitable for development and running tests, but it does not scale, does not provide any kind 
  of security, and does not provides a WebSocket frontend. So it cannot be used on production.

- **[Eclipse Mosquitto](https://mosquitto.org/)** (as of 2.0.14) works fine. It is fast, easy to
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

- Keeping a broker open for public writes is fairly risky: it will face unfriendly traffic and
  DOS attempts. Unless it is required to handle requests from frontend it is better to forbid any
  public write at all.

- Backend and frontend brokers should be run on isolated systems. Workers or routers should never
  run on same system as the frontend broker one.

- Untrusted users should not be able to write on resources which other users read. A topic open to
  the internet should be read-only, otherwise a malicious actor can inject malformed or false data
  to another users. Frontend topics `msg/*` must be read-only for end users.

- Untrusted users should not be able to read on resources which other users write. A topic open to
  the internet should be write-only, otherwise a malicious actor can disrupt a service consuming
  from the topic, as data sent to it will never reach its intended destination. It also allow to
  easily obtain data submitted by other users, which could be a security problem. Frontend topics
  `req/*` must be write-only for end users.

- Broker must be configured to discard persistent messages if possible, as Beekeeper does not rely
  on them.

- Being allowed to connect to the frontend broker does not automatically allows a client unrestricted 
  access to a Beekeeper application, it must additionally be authorized by the application itself.
  This is done in order to allow users to interact with the system even before being logged in
  (allowing unregistered users to do a checkout for example). But if this is not needed, connections
  to the frontend broker can be restricted using any access control mechanism provided by the broker.

- The authorization system implemented in workers is advisory only. It makes harder to execute a
  task with wrong permissions by mistake, but if a worker has write access to the backend bus it can
  easily override these restrictions and make any arbitrary request.

- Remote users should never ever be allowed to connect directly to the backend broker.

---

### Mosquitto setup

Install Mosquitto from official repository:
```
# wget -qO - http://repo.mosquitto.org/debian/mosquitto-repo.gpg.key | gpg --dearmor -o /usr/share/keyrings/mosquitto.gpg
# echo "deb [signed-by=/usr/share/keyrings/mosquitto.gpg] https://repo.mosquitto.org/debian bullseye main" > /etc/apt/sources.list.d/mosquitto.list

# apt update
# apt install mosquitto
```
Copy the provided configuration templates:
```
# cd /tmp
# git clone https://github.com/jmico/beekeeper.git

# cp beekeeper/doc/config/mosquitto/*.acl   /etc/mosquitto/
# cp beekeeper/doc/config/mosquitto/*.conf  /etc/mosquitto/

# cp beekeeper/doc/config/mosquitto/mosquitto.logrotate  /etc/logrotate/mosquitto
# cp beekeeper/doc/config/mosquitto/mosquitto@.service   /lib/systemd/system/
# systemctl daemon-reload
```
Edit `backend-1.conf` and `frontend-1.conf` as needed:
```
# nano /etc/mosquitto/backend-1.conf
# nano /etc/mosquitto/frontend-1.conf
```
Add broker users:
```
# mosquitto_passwd -c -b /etc/mosquitto/backend.users   backend   def456
# mosquitto_passwd -c -b /etc/mosquitto/frontend.users  frontend  abc123
# mosquitto_passwd    -b /etc/mosquitto/frontend.users  router    ghi789
```
Stop the default Mosquitto service:
```
# systemctl disable mosquitto
# service mosquitto stop
```
Start `backend-1` and `frontend-1` services:
```
# systemctl enable mosquitto@backend-1
# systemctl enable mosquitto@frontend-1
# service mosquitto@backend-1 start
# service mosquitto@frontend-1 start
```
Note that, when TLS is enabled, the certificates must be readable by `mosquitto` user:
```
# chown mosquitto: /etc/mosquitto/ca_certificates/cert.pem 
# chown mosquitto: /etc/mosquitto/certs/fullchain.pem
# chown mosquitto: /etc/mosquitto/certs/privkey.pem
# chmod 0600 /etc/mosquitto/ca_certificates/cert.pem 
# chmod 0600 /etc/mosquitto/certs/fullchain.pem
# chmod 0600 /etc/mosquitto/certs/privkey.pem
```

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
            <port>11883</port>
            <bind-address>0.0.0.0</bind-address>
        </tcp-listener>
        <websocket-listener>
            <port>18080</port>
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
