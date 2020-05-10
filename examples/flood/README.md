## Flood example

This example allows to estimate the performance of a Beekeper setup, which depends 
heavily of the performance of the message broker and the network latency. 


To run this example start a worker pool of `TestWorker` processes:
```
cd beekeper/examples/flood
source setup.sh
./run.sh
```
Then flood the worker pool with requests:
```
./flood.pl -b
```
Monitor the worker pool load:
```
bkpr-top
```
When done, stop the worker pool with:
```
./run.sh stop
```

Sample output (on a local setup):

```
# flood -b -c 1000

1000 notifications    of   0 Kb  in  0.057 sec   17673 /sec   0.06 ms each
1000 notifications    of   1 Kb  in  0.075 sec   13299 /sec   0.08 ms each
1000 notifications    of   5 Kb  in  0.084 sec   11850 /sec   0.08 ms each
1000 notifications    of  10 Kb  in  0.109 sec    9157 /sec   0.11 ms each

1000 sync jobs        of   0 Kb  in  1.533 sec     652 /sec   1.53 ms each
1000 sync jobs        of   1 Kb  in  1.542 sec     649 /sec   1.54 ms each
1000 sync jobs        of   5 Kb  in  1.692 sec     591 /sec   1.69 ms each
1000 sync jobs        of  10 Kb  in  1.920 sec     521 /sec   1.92 ms each

1000 async jobs       of   0 Kb  in  0.403 sec    2480 /sec   0.40 ms each
1000 async jobs       of   1 Kb  in  0.424 sec    2357 /sec   0.42 ms each
1000 async jobs       of   5 Kb  in  0.445 sec    2246 /sec   0.45 ms each
1000 async jobs       of  10 Kb  in  0.473 sec    2115 /sec   0.47 ms each

1000 background jobs  of   0 Kb  in  0.161 sec    6198 /sec   0.16 ms each
1000 background jobs  of   1 Kb  in  0.172 sec    5829 /sec   0.17 ms each
1000 background jobs  of   5 Kb  in  0.193 sec    5173 /sec   0.19 ms each
1000 background jobs  of  10 Kb  in  0.279 sec    3586 /sec   0.28 ms each
```

---
### RabbitMQ setup

In order to run this example you need a working instance of RabbitMQ. Enable STOMP, add 
and configure a user `test` and create a virtual host `/test` with the following commands:

```
rabbitmq-plugins enable rabbitmq_stomp

rabbitmqctl add_user test abc123

rabbitmqctl add_vhost /test

rabbitmqctl set_permissions test -p /test ".*" ".*" ".*"

rabbitmqctl set_policy expiry -p /test ".*" '{"expires":60000}' --apply-to queues
```
Also ensure that `host` address in `bus.config.json` match RabbitMQ one.
