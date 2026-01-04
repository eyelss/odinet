package odinet

import "core:fmt"
import "core:net"

Server_Space :: struct {
        active_users_count: uint,
}

main :: proc() {
        ltcp_context: LTCP_Context

        ip4_str := "localhost:8080"
        endpoint, ok := net.resolve_ip4(ip4_str)

        shared_space := Server_Space {
                active_users_count = 0,
        }

        init(&ltcp_context, endpoint, &shared_space)
        defer destroy(&ltcp_context)

        handler_begin := LTCP_Anon_Handler_Listed {
                handler = proc(ctx: ^LTCP_Context) {
                        fmt.printf("poll begin\n")
                },
        }

        handler_ended := LTCP_Anon_Handler_Listed {
                handler = proc(ctx: ^LTCP_Context) {
                        fmt.printf("poll ended\n")
                },
        }

        handler_on_connect := LTCP_Client_Handler_Listed {
                handler = proc(ctx: ^LTCP_Context, socket: net.TCP_Socket, source: net.Endpoint) {
                        space := transmute(^Server_Space)ctx.shared
                        space.active_users_count += 1
                        fmt.printf("client connected %s on socket %s, active users: %s\n", source, socket, space.active_users_count)
                },
        }

        handler_on_disconnect := LTCP_Client_Handler_Listed {
                handler = proc(ctx: ^LTCP_Context, socket: net.TCP_Socket, source: net.Endpoint) {
                        space := transmute(^Server_Space)ctx.shared
                        space.active_users_count -= 1
                        fmt.printf("client disconnected %s on socket %s, active users: %s\n", source, socket, space.active_users_count)
                },
        }

        handler_on_message := LTCP_Client_Handler_Listed {
                handler = proc(ctx: ^LTCP_Context, socket: net.TCP_Socket, source: net.Endpoint) {
                        fmt.printf("first handler: client sent message from %s on socket %s\n", source, socket)
                        fmt.printf("%s", ctx.buffer) // recieved data
                },
        }
        
        ltcp_push_on_connect(&ltcp_context, &handler_on_connect)
        ltcp_push_on_disconnect(&ltcp_context, &handler_on_disconnect)
        ltcp_push_on_message(&ltcp_context, &handler_on_message)
        // ltcp_push_on_poll_ended(&ltcp_context, &handler_ended)
        // ltcp_push_on_poll_begin(&ltcp_context, &handler_begin)
        // ltcp_remove_handler(&ltcp_context, &handler_on_connect.node)
        ltcp_loop(&ltcp_context)
}