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

Sample output running on a local ActiveMQ 5.15.12:

```
# flood -b

1000 notifications    of   0 Kb  in  0.055 sec   18187 /sec   0.05 ms each
1000 notifications    of   1 Kb  in  0.068 sec   14621 /sec   0.07 ms each
1000 notifications    of   5 Kb  in  0.072 sec   13974 /sec   0.07 ms each
1000 notifications    of  10 Kb  in  0.093 sec   10715 /sec   0.09 ms each

1000 sync jobs        of   0 Kb  in  1.438 sec     695 /sec   1.44 ms each
1000 sync jobs        of   1 Kb  in  1.448 sec     690 /sec   1.45 ms each
1000 sync jobs        of   5 Kb  in  1.628 sec     614 /sec   1.63 ms each
1000 sync jobs        of  10 Kb  in  1.974 sec     507 /sec   1.97 ms each

1000 async jobs       of   0 Kb  in  0.277 sec    3611 /sec   0.28 ms each
1000 async jobs       of   1 Kb  in  0.306 sec    3272 /sec   0.31 ms each
1000 async jobs       of   5 Kb  in  0.336 sec    2973 /sec   0.34 ms each
1000 async jobs       of  10 Kb  in  0.462 sec    2166 /sec   0.46 ms each

1000 background jobs  of   0 Kb  in  0.134 sec    7488 /sec   0.13 ms each
1000 background jobs  of   1 Kb  in  0.203 sec    4933 /sec   0.20 ms each
1000 background jobs  of   5 Kb  in  0.216 sec    4624 /sec   0.22 ms each
1000 background jobs  of  10 Kb  in  0.225 sec    4452 /sec   0.22 ms each
```
Sample output running on a local RabbitMQ 3.8.3:

```
# flood -b

1000 notifications    of   0 Kb  in  0.057 sec   17673 /sec   0.06 ms each
1000 notifications    of   1 Kb  in  0.071 sec   13990 /sec   0.07 ms each
1000 notifications    of   5 Kb  in  0.084 sec   11850 /sec   0.08 ms each
1000 notifications    of  10 Kb  in  0.099 sec   10117 /sec   0.10 ms each

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
Sample output running a ToyBroker:

```
# flood -b

1000 notifications    of   0 Kb  in  0.044 sec   22899 /sec   0.04 ms each
1000 notifications    of   1 Kb  in  0.065 sec   15456 /sec   0.06 ms each
1000 notifications    of   5 Kb  in  0.073 sec   13717 /sec   0.07 ms each
1000 notifications    of  10 Kb  in  0.092 sec   10924 /sec   0.09 ms each

1000 sync jobs        of   0 Kb  in  0.829 sec    1206 /sec   0.83 ms each
1000 sync jobs        of   1 Kb  in  0.987 sec    1013 /sec   0.99 ms each
1000 sync jobs        of   5 Kb  in  1.071 sec     934 /sec   1.07 ms each
1000 sync jobs        of  10 Kb  in  1.136 sec     880 /sec   1.14 ms each

1000 async jobs       of   0 Kb  in  0.253 sec    3960 /sec   0.25 ms each
1000 async jobs       of   1 Kb  in  0.267 sec    3750 /sec   0.27 ms each
1000 async jobs       of   5 Kb  in  0.284 sec    3525 /sec   0.28 ms each
1000 async jobs       of  10 Kb  in  0.336 sec    2975 /sec   0.34 ms each

1000 background jobs  of   0 Kb  in  0.065 sec   15472 /sec   0.06 ms each
1000 background jobs  of   1 Kb  in  0.068 sec   14602 /sec   0.07 ms each
1000 background jobs  of   5 Kb  in  0.080 sec   12462 /sec   0.08 ms each
1000 background jobs  of  10 Kb  in  0.099 sec   10082 /sec   0.10 ms each
```

---

### ActiveMQ setup

This example uses the internal ToyBroker to allow being run out of the box.

To run this example on a fresh install of ActiveMQ just set `use_toybroker` to false in config file `pool.config.json`. Also ensure that `host` addresses in `bus.config.json` and `config.js` match ActiveMQ one.

**WARNING:** A fresh install of ActiveMQ is completly open and does not provide any kind of security.


### RabbitMQ setup

To run this example on a fresh install of RabbitMQ set `use_toybroker` to false in config file
`pool.config.json`. Also ensure that `host` addresses in `bus.config.json` and `config.js` match RabbitMQ one.

Then configure RabbitMQ (enable STOMP, add an user `test` and a virtual host `/test`) with the following commands:

```
rabbitmq-plugins enable rabbitmq_stomp

rabbitmqctl add_user test abc123

rabbitmqctl add_vhost /test

rabbitmqctl set_permissions test -p /test ".*" ".*" ".*"

rabbitmqctl set_policy expiry -p /test ".*" '{"expires":60000}' --apply-to queues
```
