## Dashboard

![](../../doc/images/dashboard.png)

To use the dashboard start the worker pool:
```
cd beekeper/examples/dashboard
source setup.sh
./run.sh
```
Then open `dashboard.html` in a browser. 

Logs can be inspected with `bkpr-log` or with:
```
tail /var/log/myapp-pool.log
tail /var/log/myapp-service-dashboard.log
```
Finally stop the worker pool with:
```
./run.sh stop
```
---

### Dashboard users setup

Dashboard users must be declared into config file `dashboard.config.json`:

```
{
    "users": {
        "admin": { "password": "eea8d7042107a675..." },
        "guest": { "password": "60c8d0904b5deb4c..." },
    },
}
```
You will need to reset passwords before being able to login into the dashboard.  
Use the following command to hash passwords of dashboard users:

```
echo "Username:" && read U && echo "Password:" && read -s P && echo -n "Dashboard$U$P" | shasum -a 256 && U= P=
```
---

### Mosquitto setup

This dashboard uses WebSockets, so it cannot be run with ToyBroker: a real broker like
[Mosquitto](https://mosquitto.org/) is required. Follow the instructions below to quickly 
setup a Mosquitto instance capable of running Beekeper applications with minimal security. 

Please note that the entire idea is to have the backend and frontend buses serviced by different broker 
instances, running on isolated servers. This setup uses a single broker instance for simplicity, and works 
just because topics do not clash (see [Brokers.md](../../doc/Brokers.md) for a proper configuration).

Create `/etc/mosquitto/conf.d/beekeeper.conf`
```
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
password_file /etc/mosquitto/conf.d/beekeeper.users

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
password_file /etc/mosquitto/conf.d/beekeeper.users
```
Create `/etc/mosquitto/conf.d/beekeeper.backend.acl`
```
pattern  read   priv/%c/#

user backend

topic   readwrite   msg/#
topic   readwrite   req/#
topic   readwrite   res/#
topic   readwrite   log/#
topic   write       priv/#
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
mosquitto_passwd -c -b /etc/mosquitto/conf.d/beekeeper.users  frontend  abc123
mosquitto_passwd    -b /etc/mosquitto/conf.d/beekeeper.users  backend   def456
mosquitto_passwd    -b /etc/mosquitto/conf.d/beekeeper.users  router    ghi789
```
Then the Mosquitto broker instance can be started with:
```
mosquitto -c /etc/mosquitto/conf.d/beekeeper.conf
```
If the broker is running elsewhere than localhost edit `bus.config.json` and `config.js` accordingly.

Mosquitto can serve http data as well, when setting the `http_dir` configuration option.
This feature can be used in simple projects to host the html files of the dashboard.

---

### Acknowledgements

This software uses the following libraries:

- Semantic UI - https://semantic-ui.com/  
  Released under the terms of the MIT license

- jQuery - https://jquery.com/  
  Released under the terms of the MIT license

- MQTT.js - https://github.com/mqttjs/MQTT.js  
  Released under the terms of the MIT license

- D3.js - https://d3js.org/  
  Released under the terms of the ISC license

- DataTables - https://datatables.net/  
  Released under the terms of the MIT license
