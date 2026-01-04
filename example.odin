package odinet

import "core:fmt"
import "core:net"

main :: proc() {
        ltcp_context: LTCP_Context

        ip4_str := "localhost:8080"
        endpoint, ok := net.resolve_ip4(ip4_str)

        init(&ltcp_context, endpoint)
        defer destroy(&ltcp_context)

        handler_begin := LTCP_Anon_Handler_Listed {
                handler = proc(ctx: ^LTCP_Context) {
                        fmt.printf("begin\n")
                },
        }

        handler_ended := LTCP_Anon_Handler_Listed {
                handler = proc(ctx: ^LTCP_Context) {
                        fmt.printf("end\n")
                },
        }

        handler_on_connect := LTCP_Client_Handler_Listed {
                handler = proc(ctx: ^LTCP_Context, socket: net.TCP_Socket, source: net.Endpoint) {
                        fmt.printf("client connected %s on socket %s\n", source, socket)
                },
        }

        handler_on_disconnect := LTCP_Client_Handler_Listed {
                handler = proc(ctx: ^LTCP_Context, socket: net.TCP_Socket, source: net.Endpoint) {
                        fmt.printf("client disconnected %s on socket %s\n", source, socket)
                },
        }

        handler_on_message1 := LTCP_Client_Handler_Listed {
                handler = proc(ctx: ^LTCP_Context, socket: net.TCP_Socket, source: net.Endpoint) {
                        fmt.printf("first handler: client sent message from %s on socket %s\n", source, socket)
                        fmt.printf("%s", ctx.buffer) // recieved data
                },
        }

        handler_on_message2 := LTCP_Client_Handler_Listed {
                handler = proc(ctx: ^LTCP_Context, socket: net.TCP_Socket, source: net.Endpoint) {
                        fmt.printf("second handler: client sent message from %s on socket %s\n", source, socket)
                        ctx.output = transmute([]u8)string("message") // data that will be outputed
                },
        }
        
        ltcp_push_on_connect(&ltcp_context, &handler_on_connect)
        ltcp_push_on_disconnect(&ltcp_context, &handler_on_disconnect)
        ltcp_push_on_message(&ltcp_context, &handler_on_message1)
        ltcp_push_on_message(&ltcp_context, &handler_on_message2)
        // ltcp_push_on_poll_ended(&ltcp_context, &handler_ended)
        // ltcp_push_on_poll_begin(&ltcp_context, &handler_begin)
        ltcp_remove_handler(&ltcp_context, &handler_on_connect.node)
        ltcp_loop(&ltcp_context)
}