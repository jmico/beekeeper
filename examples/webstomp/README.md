## WebStomp example

This example shows how to use services from browsers using WebSockets.


To run this example start the worker pool:
```
cd beekeper/examples/webstomp
source setup.sh
./run.sh
```
Then open `client.html` in a browser, or use the command line client:
```
./client.pl
```
When done, stop the worker pool with:
```
./run.sh stop
```

---
### RabbitMQ setup

This example uses the internal ToyBroker to allow being run out of the box, but to use `chat.html` the WebSockets capabilities of RabbitMQ are required (`chat.pl` works fine though).

To run this example using RabbitMQ set `use_toybroker` to false in config files, and configure RabbitMQ (enable STOMP, add an user `test` and a virtual host `/test`) with the following commands:

```
rabbitmq-plugins enable rabbitmq_stomp
rabbitmq-plugins enable rabbitmq_web_stomp

rabbitmqctl add_user test abc123

rabbitmqctl add_vhost /test

rabbitmqctl set_permissions test -p /test ".*" ".*" ".*"

rabbitmqctl set_policy expiry -p /test ".*" '{"expires":60000}' --apply-to queues
```
Also ensure that `host` addresses in `bus.config.json` and `config.js` match RabbitMQ one.

---

This example uses the STOMP.js library Copyright 2010-2013 [Jeff Mesnil](http://jmesnil.net/), Copyright 2012 [FuseSource, Inc.](http://fusesource.com), Copyright 2017 [Deepak Kumar](https://www.kreatio.com).
Currently maintained at <https://github.com/stomp-js/stomp-websocket>.
