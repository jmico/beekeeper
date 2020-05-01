
function Calculator () { return {

    rpc: null,

    connect: function() {

        var This = this;

        this.rpc = new JSON_RPC;
        this.rpc.connect({
   
            url:      CONFIG.url,       // "ws://localhost:15674/ws"
            login:    CONFIG.login,     // "test"
            password: CONFIG.password,  // "abc123"
            vhost:    CONFIG.vhost,     // "/test"
            debug:    CONFIG.debug,

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
            method: "myapp.adserver.ads",
            on_receive: function(params) {
                This.echo("AD: " + params.msg, 'info');
            }
        });

        var cmdInput = document.getElementById('expr');
        cmdInput.onkeypress = function(e) {
            var event = e || window.event;
            var charCode = event.which || event.keyCode;
            if (charCode == '13') { // Enter
                This.eval_expr();
                return false;
            }
        }
    },

    echo: function(msg,style) {
        var div = document.getElementById('results');
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

    eval_expr: function() {

        var cmdInput = document.getElementById('expr');
        var expr = cmdInput.value;
        if (!expr.length) return;

        var This = this;

        this.rpc.call({
            method: 'myapp.calculator.eval_expr', 
            params: { "expr": expr },
            on_success: function(result) {
                This.echo_msg( expr + " = " + result );
            },
            on_error: function(error) {
                This.echo_error( expr + " : " + error.message );
            }
        });
    }
}};
