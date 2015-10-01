
function Chat () { return {

    rpc: null,

    connect: function() {

        var This = this;

        this.rpc = new JSON_RPC;
        this.rpc.connect({

         // url:      "ws://localhost:61633/test",               // plain websocket
         // url:      "http://jessie.local:15674/stomp",         // SockJS emulation
            url:      "ws://jessie.local:15674/stomp/websocket", // RabbitMQ websocket
            vhost:    "/frontend-1",
            login:    "frontend",
            password: "abc123",
            debug:    true,

            on_ready: function() {
                This.echo_info( 'Connected to ' + This.rpc.server + ' at ' + This.rpc.stomp.ws.url );
                This.echo_info( 'Debug enabled, STOMP traffic is being dumped to console' );
                This.init();
            }
        });
    },

    init: function() {

        var This = this;

        this.rpc.accept_notifications({
            method: "myapp.chat.message",
            on_receive: function(params) {
                var msg = params.message;
                var from = params.from;
                This.echo_msg( from + ": " + msg );
            }
        });

        this.rpc.accept_notifications({
            method: "myapp.chat.pmessage",
            on_receive: function(params) {
                var msg = params.message;
                var from = params.from;
                This.echo_msg( "PM " + from + ": " + msg );
            }
        });

        var cmdInput = document.getElementById('cmd');
        cmdInput.onkeypress = function(e) {
            var event = e || window.event;
            var charCode = event.which || event.keyCode;
            if (charCode == '13') { // Enter
                This.exec_command();
                return false;
            }
        }
    },

    echo: function(msg,style) {
        var div = document.getElementById('chat');
        div.innerHTML = div.innerHTML + '<div class="'+style+'">' + msg + '</div>';
        div.scrollTop = div.scrollHeight;
    },

    echo_msg: function(msg) {
        this.echo(msg,'msg');
    },

    echo_info: function(msg) {
        this.echo(msg,'info');
    },

    echo_error: function(msg) {
        this.echo(msg,'error');
    },

    exec_command: function() {

        var cmdInput = document.getElementById('cmd');
        var cmd = cmdInput.value;
        if (!cmd.length) return;
        cmdInput.value = "";
        var This = this;

        if (params = cmd.match(/^LOGIN\s+(.*)/i)) {
            this.rpc.call({
                method: 'myapp.auth.login', 
                params: { "username": params[1] },
            });
        }
        else if (params = cmd.match(/^LOGOUT/i)) {
            this.rpc.call({
                method: 'myapp.auth.logout', 
                params: { },
            });
        }
        else if (params = cmd.match(/^KICK\s+(.*)/i)) {
            this.rpc.call({
                method: 'myapp.auth.kick', 
                params: { "username": params[1] },
            });
        }
        else if (params =  cmd.match(/^PM\s+(\w+)(.*)/i)) {
            this.rpc.call({
                method: 'myapp.chat.pmessage', 
                params: { "username": params[1], "message": params[2] },
            });
        }
        else if (params = cmd.match(/^=(.*)$/)) {
            this.rpc.call({
                method: 'myapp.math.calculate', 
                params: { "expr": params[1] },
                on_success: function(result) {
                    This.echo_msg( params[1] + " = " + result );
                },
                on_error: function(error) {
                    This.echo_error( params[1] + " : " + error.data );
                }
            });
        }
        else if (params = cmd.match(/^PING/i)) {
            var t0 = performance.now();
            this.rpc.call({
                method: 'myapp.chat.ping', 
                params: { },
                on_success: function(result) {
                    var took = Math.round(performance.now() - t0);
                    This.echo_info( 'Ping: ' + took + " ms" );
                }
            });
        }
        else {
            this.rpc.call({
                method: 'myapp.chat.message', 
                params: { "message": cmd },
            });
        }
    }
}};
