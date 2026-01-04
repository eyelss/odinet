package odinet

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:container/intrusive/list"

TCP_Client :: struct {
        node: list.Node,
        socket: net.TCP_Socket,
        source: net.Endpoint
}

LTCP_Context :: struct {
        socket: net.TCP_Socket,
        buffer: []u8,                   // recv client stream
        output: []u8,                   // send client stream
        recv_err: net.TCP_Recv_Error,   // err on clint recv

        using tcp_clients: LTCP_Clients,
        using client_handlers: LTCP_Handlers, 
}

LTCP_Clients :: struct {
        clients: list.List,
}

LTCP_Handlers :: struct {
        on_error_handlers: list.List,
        on_message_handlers: list.List,
        on_connect_handlers: list.List,
        on_disconnect_handlers: list.List,
        on_poll_begin_handlers: list.List,
        on_poll_ended_handlers: list.List,
}

LTCP_Opcode :: enum {
        NIL,
        TEXT,
        BINARY
}

LTCP_Client_Handler_Listed :: struct {
        node: list.Node,
        handler: LTCP_Client_Handler,
}

LTCP_Client_Handler :: #type proc(
        ctx: ^LTCP_Context,
        socket: net.TCP_Socket,
        source: net.Endpoint,
)

LTCP_Anon_Handler_Listed :: struct {
        node: list.Node,
        handler: LTCP_Anon_Handler,
}

LTCP_Anon_Handler :: #type proc(
        ctx: ^LTCP_Context
)

execute_anon_handlers :: proc(
        ctx: ^LTCP_Context,
        handlers: list.List
) {
        handlers_iter := list.iterator_head(handlers, LTCP_Anon_Handler_Listed, "node")

        for handler_listed in list.iterate_next(&handlers_iter) {
                handler_listed.handler(ctx)
        }        
}

execute_client_handlers :: proc(
        ctx: ^LTCP_Context,
        socket: net.TCP_Socket,
        source: net.Endpoint,
        handlers: list.List
) {
        handlers_iter := list.iterator_head(handlers, LTCP_Client_Handler_Listed, "node")

        for handler_listed in list.iterate_next(&handlers_iter) {
                handler_listed.handler(ctx, socket, source)
        }
}

DEFAULT_LTCP_BUFFER_SIZE :: 4096
DEFAULT_LTCP_OUTPUT_SIZE :: 4096

init :: proc(
        ctx: ^LTCP_Context,
        endpoint: net.Endpoint,
        buffer_size := DEFAULT_LTCP_BUFFER_SIZE,
        output_size := DEFAULT_LTCP_OUTPUT_SIZE
) {
        socket, err_listen := net.listen_tcp(endpoint)

        net.set_blocking(socket, false)

        net.set_option(socket, net.Socket_Option.Reuse_Address, true)        
        
        ctx.socket = socket
        ctx.buffer = make([]u8, buffer_size)
        ctx.output = make([]u8, output_size)
        ctx.recv_err = .None

        clients: list.List
        clients_to_remove: [dynamic]^TCP_Client
}

destroy :: proc(ctx: ^LTCP_Context) {
        defer {
                delete(ctx.buffer)
                delete(ctx.output)
        }
        
        net.close(ctx.socket)
}

LTCP_Poll_Status :: enum {
        PENDING,
        GOOD,
        ERROR
}

LTCP_Poll_Error :: union {
        net.Accept_Error
}

ltcp_poll :: proc(ctx: ^LTCP_Context) -> (status: LTCP_Poll_Status, error: LTCP_Poll_Error) {
        error = .None

        execute_anon_handlers(ctx, ctx.on_poll_begin_handlers)
        defer execute_anon_handlers(ctx, ctx.on_poll_ended_handlers)

        clients_iter := list.iterator_head(ctx.clients, TCP_Client, "node")
        clients_to_remove: [dynamic]^TCP_Client

        for client in list.iterate_next(&clients_iter) {
                n_read, err := net.recv(client.socket, ctx.buffer)

                ctx.recv_err = err

                if err == .Would_Block {
                        // pending
                        continue
                } else if err != .None {
                        // got error (including "Connection_Closed")
                        execute_client_handlers(ctx, client.socket, client.source, ctx.on_error_handlers)

                        append(&clients_to_remove, client)
                        
                        continue
                } else if n_read == 0 {
                        // got 0 bytes, assume connection has to be closed
                        append(&clients_to_remove, client)
                        
                        continue
                }
                
                // No error + message recieved
                execute_client_handlers(ctx, client.socket, client.source, ctx.on_message_handlers)
                
                net.send(client.socket, ctx.output)
        }
        // clear clients on scheduled on remove
        for client_to_remove in clients_to_remove {
                list.remove(&ctx.clients, &client_to_remove.node)
                
                free(client_to_remove)
                
                execute_client_handlers(
                        ctx,
                        client_to_remove.socket,
                        client_to_remove.source,
                        ctx.on_disconnect_handlers
                )
        }
        clear(&clients_to_remove)
        client, source, err_accept := net.accept_tcp(ctx.socket)
        if err_accept == .Would_Block {
                status = .PENDING
                error = .None
        } else if err_accept != .None {
                status = .ERROR
                error = err_accept
        } else {
                status = .GOOD
                error = .None

                // new connection established, adding new active user
                client_list_value_ptr := new_clone(TCP_Client {
                        socket=client,
                        source=source
                })
                
                list.push_back(&ctx.clients, &client_list_value_ptr.node)
                execute_client_handlers(ctx, client, source, ctx.on_connect_handlers)
        }

        return
 }

ltcp_loop :: proc(
        ctx: ^LTCP_Context
) {
        for {
                ltcp_poll(ctx)
        }
}

ltcp_push_on_poll_begin :: proc(ctx: ^LTCP_Context, handler: ^LTCP_Anon_Handler_Listed) {
        list.push_back(
                &ctx.on_poll_begin_handlers,
                &handler.node
        )
}

ltcp_push_on_poll_ended :: proc(ctx: ^LTCP_Context, handler: ^LTCP_Anon_Handler_Listed) {
        list.push_back(
                &ctx.on_poll_ended_handlers,
                &handler.node
        )
}

ltcp_push_on_error :: proc(ctx: ^LTCP_Context, handler: ^LTCP_Client_Handler_Listed) {
        list.push_back(
                &ctx.on_error_handlers,
                &handler.node
        )
}

ltcp_push_on_connect :: proc(ctx: ^LTCP_Context, handler: ^LTCP_Client_Handler_Listed) {
        list.push_back(
                &ctx.on_connect_handlers,
                &handler.node
        )
}

ltcp_push_on_disconnect :: proc(ctx: ^LTCP_Context, handler: ^LTCP_Client_Handler_Listed) {
        list.push_back(
                &ctx.on_disconnect_handlers,
                &handler.node
        )
}

ltcp_push_on_message :: proc(ctx: ^LTCP_Context, handler: ^LTCP_Client_Handler_Listed) {
        list.push_back(
                &ctx.on_message_handlers,
                &handler.node
        )
}

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
                        fmt.printf("new client connected %s on socket %s\n", source, socket)
                },
        }

        ltcp_push_on_connect(&ltcp_context, &handler_on_connect)
        ltcp_push_on_poll_ended(&ltcp_context, &handler_ended)
        ltcp_push_on_poll_begin(&ltcp_context, &handler_begin)
        ltcp_loop(&ltcp_context)
}