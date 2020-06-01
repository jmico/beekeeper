## Supported brokers

- **ActiveMQ** (as of 5.15.12) works perfectly. It is a mature product and has good community support. On the downside it does not support STOMP virtual hosts, so it is not practical to emulate complex topologies 
(simple pairs frontend/backend works anyway because queue names do not clash).

- **RabbitMQ** (as of 3.8.3) works perfectly. It is also a mature product, but it has not good support about STOMP issues (and good luck reading its Erlang source code). Also cannot be used in a frontend role because its STOMP permissions are not flexible enough to restrict unwanted consumption from `/queue/req.backend`.

- **ToyBroker** works perfectly but does not scale and does not provide a WebSockets frontend. It is intended for development or running tests only.

- **Artemis** support is in progress.

Beekeeper, being broker agnostic as much as possible, allows to switch brokers at any time or mix them in different roles.


## Security notes

- Enable TLS on any production system.

- Keeping a broker open for public writes is fairly risky: it will face unfriendly traffic and DOS attempts. Unless it is required to handle low latency requests from frontend it is better to forbid any public write at all.

- Backend and frontend brokers should be run on isolated systems. Workers or routers should never run on same system as the frontend broker one.

- Untrusted users should not be able to write on resources which other users read. A /topic open to the internet should be read-only, otherwise a malicious actor can inject malformed or false data to another users. Frontend topics `msg.frontend.*` must be read-only for end users.

- Untrusted users should not be able to read on resources which other users write. A /queue open to the internet should be write-only, otherwise a malicious actor can disrupt a service consuming from the queue, as data sent to it will never reach its intended destination. It also allow to easily obtain data submitted by other users, which could be a security problem. Frontend queues `req.backend-n` must be write-only for end users.

- Broker must be configured to discard old, unconsumed messages. Otherwise it may eventually run out of memory.


## ActiveMQ configuration

A fresh install of ActiveMQ is completly open and does not provide any kind of security, thus examples can be run out of the box.

To setup a restricted basic configuration suitable to run examples add to `broker.xml`:

```
<plugins>
  <simpleAuthenticationPlugin>
    <users>
      <authenticationUser username="frontend" password="abc123" groups="users,all"  />
      <authenticationUser username="backend"  password="def456" groups="admins,all" />
      <authenticationUser username="test"     password="abc123" groups="admins,all" />
    </users>
  </simpleAuthenticationPlugin>
  <authorizationPlugin>
    <map>
      <authorizationMap>
        <authorizationEntries>
          <!-- By default require admin group privileges -->
          <authorizationEntry queue=">" read="admins" write="admins" admin="admins" />
          <authorizationEntry topic=">" read="admins" write="admins" admin="admins" />
          <!-- Allow specific access to users group -->
          <authorizationEntry queue="req.backend-1"  read="admins" write="all"    admin="admins" />
          <authorizationEntry queue="req.backend-2"  read="admins" write="all"    admin="admins" />
          <authorizationEntry topic="msg.frontend.>" read="all"    write="admins" admin="admins" />
          <!-- All users create advisory messages (can be disabled if not needed) -->
          <authorizationEntry topic="ActiveMQ.Advisory.>" read="admins" write="all" admin="all" />
        </authorizationEntries>
      </authorizationMap>
    </map>
  </authorizationPlugin>
  <!-- 60000 ms = 1 minute -->
  <timeStampingBrokerPlugin ttlCeiling="60000" zeroExpirationOverride="60000"/>
</plugins>
```
A complex STOMP only configuration can be found [here](https://activemq.apache.org/complex-single-broker-configuration-stomp-only).


## RabbitMQ configuration

A fresh install of RabbitMQ need to be configured in order to run examples.

Enable STOMP and create the required users and virtual hosts with the following commands:

```
rabbitmq-plugins enable rabbitmq_stomp
rabbitmq-plugins enable rabbitmq_web_stomp

rabbitmqctl add_user frontend abc123
rabbitmqctl add_user backend def456
rabbitmqctl add_user test abc123

rabbitmqctl add_vhost /frontend
rabbitmqctl add_vhost /backend
rabbitmqctl add_vhost /test

rabbitmqctl set_permissions frontend -p /frontend ".*" ".*" ".*"
rabbitmqctl set_permissions backend  -p /backend  ".*" ".*" ".*"
rabbitmqctl set_permissions backend  -p /frontend ".*" ".*" ".*"
rabbitmqctl set_permissions test     -p /test     ".*" ".*" ".*"

rabbitmqctl set_policy expiry -p /backend  ".*" '{"expires":60000}' --apply-to queues
rabbitmqctl set_policy expiry -p /frontend ".*" '{"expires":60000}' --apply-to queues
rabbitmqctl set_policy expiry -p /test     ".*" '{"expires":60000}' --apply-to queues

rabbitmqctl set_topic_permissions frontend -p /frontend amq.topic "" "^msg.frontend.*"
```
Currently there is no way to restrict unwanted consumption from `/queue/req.backend-n`, which prevents RabbitMQ from being used as a frontend broker.
