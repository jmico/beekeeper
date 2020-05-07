## Basic example

This is a working barebones example of the usage of Beekeper.


To run this example start a worker pool of `MyWorker` processes:
```
cd beekeper/examples/basic
source setup.sh
./run.sh
```
Then make a request to the worker pool, using `MyClient` client:
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

rabbitmqctl add_user test abc123

rabbitmqctl add_vhost /test

rabbitmqctl set_permissions test -p /test ".*" ".*" ".*"

rabbitmqctl set_policy expiry -p /test ".*" '{"expires":60000}' --apply-to queues
```
Also ensure that `host` address in `bus.config.json` match RabbitMQ one.
