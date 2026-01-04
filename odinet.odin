package odinet

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:container/intrusive/list"

LTCP_Client :: struct {
        node: list.Node,
        socket: net.TCP_Socket,
        source: net.Endpoint
}

/*
LTCP Context - unified structure for control of LTCP activity

**Props**
- socket: Listen socket TCP address 
- endpoint: Listen socket TCP endpoint
- buffer: Buffer for recieving data
- output: Buffer for sending data
- recv_err: Error on recieved data from client
- tcp_clients: List of currently active tcp clients
- client_handlers: Lists of attached handlers
*/
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

/*
LTCP Handlers struct.

**Props**
- on_error_handlers: List of error client handlers - executes if error occured on tcp recv,
- on_message_handlers: List of message client handlers - executes if got message on tcp recv,
- on_connect_handlers: List of new client connection handlers - executes on tcp accept,
- on_disconnect_handlers: List of client disconnection handlers - exectues on 0-bytes recv or recv error after removing client from clients list,
- on_poll_begin_handlers: List of poll begin handlers - exectues at beginning of poll proc,
- on_poll_ended_handlers: List of poll end handlers - exectues as defers of poll proc
*/
LTCP_Handlers :: struct {
        // client handlers
        on_error_handlers: list.List,
        on_message_handlers: list.List,
        on_connect_handlers: list.List,
        on_disconnect_handlers: list.List,

        // anon handlers
        on_poll_begin_handlers: list.List,
        on_poll_ended_handlers: list.List,
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

LTCP_Poll_Status :: enum {
        PENDING,
        GOOD,
        ERROR
}

LTCP_Poll_Error :: union {
        net.Accept_Error
}

@(private)
execute_anon_handlers :: proc(
        ctx: ^LTCP_Context,
        handlers: list.List
) {
        handlers_iter := list.iterator_head(handlers, LTCP_Anon_Handler_Listed, "node")

        for handler_listed in list.iterate_next(&handlers_iter) {
                handler_listed.handler(ctx)
        }        
}

@(private)
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

/*
Initialize LTCP context.

**Inputs**
- ctx: The uninitialized context of LTCP 
- endpoint: The listening endpoint
- buffer_size: Size of input buiffer := DEFAULT_LTCP_BUFFER_SIZE
- output_size: Size of output buiffer := DEFAULT_LTCP_OUTPUT_SIZE
*/
init :: proc(
        ctx: ^LTCP_Context,
        endpoint: net.Endpoint,
        buffer_size := DEFAULT_LTCP_BUFFER_SIZE,
        output_size := DEFAULT_LTCP_OUTPUT_SIZE
) -> net.Network_Error {
        socket, err_listen := net.listen_tcp(endpoint)

        net.set_blocking(socket, false)

        if err_listen != nil {
                return err_listen
        }

        net.set_option(socket, net.Socket_Option.Reuse_Address, true)        
        
        ctx.socket = socket
        ctx.buffer = make([]u8, buffer_size)
        ctx.output = make([]u8, output_size)
        ctx.recv_err = .None

        return nil
}

/*
Destroy LTCP context.

**Inputs**
- ctx: The initialized context of LTCP
*/
destroy :: proc(ctx: ^LTCP_Context) {
        defer {
                delete(ctx.buffer)
                delete(ctx.output)
        }
        
        net.close(ctx.socket)
}

ltcp_poll :: proc(ctx: ^LTCP_Context) -> (status: LTCP_Poll_Status, error: LTCP_Poll_Error) {
        error = .None

        execute_anon_handlers(ctx, ctx.on_poll_begin_handlers)
        defer execute_anon_handlers(ctx, ctx.on_poll_ended_handlers)

        clients_iter := list.iterator_head(ctx.clients, LTCP_Client, "node")
        clients_to_remove: [dynamic]^LTCP_Client

        for client in list.iterate_next(&clients_iter) {
                n_read, err := net.recv(client.socket, ctx.buffer)
                ctx.recv_err = err

                if err == .Would_Block {
                        // pending
                        continue
                } else if err != .None {
                        // got error (including "Connection_Closed")
                        ctx.recv_err = err
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
                defer free(client_to_remove)
                
                execute_client_handlers(
                        ctx,
                        client_to_remove.socket,
                        client_to_remove.source,
                        ctx.on_disconnect_handlers
                )

                list.remove(&ctx.clients, &client_to_remove.node)
        }
        clear(&clients_to_remove)

        client, source, err_accept := net.accept_tcp(ctx.socket)

        if err_accept == .Would_Block {
                status = .PENDING
        } else if err_accept != .None {
                error = err_accept
                status = .ERROR
        } else {
                status = .GOOD

                // new connection established, adding new active user
                client_list_value_ptr := new_clone(LTCP_Client {
                        socket=client,
                        source=source
                })
                
                list.push_back(&ctx.clients, &client_list_value_ptr.node)
                execute_client_handlers(ctx, client, source, ctx.on_connect_handlers)
        }

        return
}


/*
Infinite loop of polling
*/
ltcp_loop :: proc(ctx: ^LTCP_Context) {
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

ltcp_remove_handler :: proc(ctx: ^LTCP_Context, node: ^list.Node) {
        list.remove(&ctx.on_error_handlers, node)
        list.remove(&ctx.on_message_handlers, node)
        list.remove(&ctx.on_connect_handlers, node)
        list.remove(&ctx.on_disconnect_handlers, node)
        list.remove(&ctx.on_poll_begin_handlers, node)
        list.remove(&ctx.on_poll_ended_handlers, node)
}