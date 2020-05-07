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

In order to run this example you need a working instance of RabbitMQ. Enable STOMP, add and configure a 
user `test` and create a virtual host `/test` with the following commands:

```
rabbitmq-plugins enable rabbitmq_stomp
rabbitmq-plugins enable rabbitmq_web_stomp

rabbitmqctl add_user test abc123

rabbitmqctl add_vhost /test

rabbitmqctl set_permissions test -p /test ".*" ".*" ".*"

rabbitmqctl set_policy expiry -p /test ".*" '{"expires":60000}' --apply-to queues
```
Also ensure that `host` addresses in `bus.config.json` and `config.js` match RabbitMQ one.
