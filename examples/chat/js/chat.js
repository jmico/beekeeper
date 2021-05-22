
function Chat () { return {

    bkpr: null,

    connect: function() {

        const This = this;

        this.bkpr = new BeekeeperClient;

        this.bkpr.connect({
            url:        CONFIG.url,       // "ws://localhost:8000/mqtt"
            username:   CONFIG.username,  // "frontend"
            password:   CONFIG.password,  // "abc123"
            debug:      CONFIG.debug,
            on_connect: function() { This.init() }
        });
    },

    init: function() {

        //This.echo_info( 'Connected to ' + This.bkpr.server + ' at ' + This.bkpr.stomp.ws.url );
        //This.echo_info( 'Debug enabled, STOMP traffic is being dumped to console' );

        const This = this;

        This.login_user();

        this.bkpr.accept_notifications({
            method: "myapp.chat.message",
            on_receive: function(params) {
                const msg = params.message;
                const from = params.from;

                This.bubble( from, msg, 'mine' );
            }
        });

        this.bkpr.accept_notifications({
            method: "myapp.chat.pmessage",
            on_receive: function(params) {
                const msg = params.message;
                const from = params.from;
                This.echo_ucast( from ? from + ": " + msg : msg );
            }
        });

        this.bkpr.on_error = function(error) {
            const errstr = error.constructor === Object ? error.message : error;
            This.echo_error(errstr);
        }

        const cmdInput = document.getElementById('cmd');
        cmdInput.onkeypress = function(e) {
            const event = e || window.event;
            const charCode = event.which || event.keyCode;
            if (charCode == '13') { // Enter
                This.exec_command();
                return false;
            }
        }
    },

    echo: function(msg,style) {
        const div = document.getElementById('chat');
        div.innerHTML = div.innerHTML + '<div class="'+style+'">' + msg + '</div>';
        div.scrollTop = div.scrollHeight;
    },

    bubble: function(from,msg,style) {
        const div = document.getElementById('chat');
        div.innerHTML = div.innerHTML + `<div class="bubble ${style}"><div class="sender">${from}</div>${msg}</div>`;
        div.scrollTop = div.scrollHeight;
    },

    echo_info: function(msg) {
        //this.echo(msg,'info');
        this.bubble( 'sys', msg, 'info nonmine' );
    },

    echo_error: function(msg) {
        //this.echo(msg,'error');
        this.bubble( 'error', msg, 'error nonmine' );
    },

    echo_mcast: function(msg) {
        //this.echo(msg,'mcast');
        this.bubble( 'sys', msg, 'mcast nonmine' );
    },

    echo_ucast: function(msg) {
        //this.echo(msg,'ucast');
        this.bubble( 'sys', msg, 'ucast nonmine' );
    },

    login_user: function() {
        const This = this;
        this.bkpr.call_remote_method({
            method: 'myapp.auth.login', 
            params: {
                "username": document.getElementById('username').value,
                "password": document.getElementById('password').value
            }
        });
    },

    exec_command: function() {

        const cmdInput = document.getElementById('cmd');
        const cmd = cmdInput.value;
        if (!cmd.length) return;
        cmdInput.value = "";
        const This = this;
        let params;

        if (params = cmd.match(/^\/logout\b/i)) {
            this.bkpr.call_remote_method({
                method: 'myapp.auth.logout', 
                params: { }
            });
        }
        else if (params = cmd.match(/^\/kick\s+(.*)/i)) {
            this.bkpr.call_remote_method({
                method: 'myapp.auth.kick', 
                params: { "username": params[1] }
            });
        }
        else if (params =  cmd.match(/^\/pm\s+(\w+)\s+(.*)/i)) {
            this.bkpr.call_remote_method({
                method: 'myapp.chat.pmessage', 
                params: { "to_user": params[1], "message": params[2] }
            });
        }
        else if (params = cmd.match(/^\/ping\b/i)) {
            const t0 = performance.now();
            this.bkpr.call_remote_method({
                method: 'myapp.chat.ping', 
                params: { },
                on_success: function(result) {
                    const took = Math.round(performance.now() - t0);
                    This.echo_info( `Ping: ${took} ms` );
                }
            });
        }
        else {
            this.bkpr.call_remote_method({
                method: 'myapp.chat.message', 
                params: { "message": cmd }
            });
        }
    }
}};

const chat = new Chat;
chat.connect();
