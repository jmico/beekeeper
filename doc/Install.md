## How to run Beekeeper pools as systemd services

Install Beekeeper dependencies:
```
# apt install libanyevent-perl libjson-xs-perl libnet-ssleay-perl libterm-readkey-perl procps
```
Install Beekeeper from CPAN:
```
# apt install make cpanminus
# cpanm --sudo --notest Beekeeper
```
Create an user `beekeeper`:
```
# adduser beekeeper
```
Copy the provided configuration templates:
```
# cd /tmp
# git clone https://github.com/jmico/beekeeper.git

# mkdir /etc/beekeeper
# cp beekeeper/doc/config/beekeeper/*.config.json  /etc/beekeeper/
# cp beekeeper/doc/config/beekeeper/*.environment  /etc/beekeeper/
# chown beekeeper: /etc/beekeeper/*
# chmod 0600 /etc/beekeeper/*

# cp beekeeper/doc/config/beekeeper/beekeeper.logrotate  /etc/logrotate/beekeeper
# cp beekeeper/doc/config/beekeeper/beekeeper@.service   /lib/systemd/system/
# systemctl daemon-reload
```
Copy the examples to `/home/beekeeper`:
```
# cp beekeeper/doc/config/beekeeper/myapp  /home/beekeeper/
# cp beekeeper/examples  /home/beekeeper/
# chown -R beekeeper: /home/beekeeper/myapp /home/beekeeper/examples
```
Edit `pool.config.json` and `bus.config.json` as needed, and ensure that credentials are correct:
```
# nano /etc/beekeeper/pool.config.json
# nano /etc/beekeeper/bus.config.json
```
When starting a service `beekeeper@{POOL_ID}` the provided systemd unit template loads `PERL5LIB`
and any other environment variable from `{POOL_ID}.environment`, then starts the pool `{POOL_ID}`
defined in `pool.config.json`.

Start the test pool `myapp`:
```
# service beekeeper@myapp start
```
Check that everything is ok:
```
# service beekeeper@myapp status
# tail /var/log/beekeeper/myapp.pool.log
# bkpr-top -b
```
Enable the service to start it at boot:
```
# systemctl enable beekeeper@myapp
```
