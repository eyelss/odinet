# Looped TCP Server

Basic event-drivent non-blocking TCP implementation

- inject into your own event loop by `ltcp_poll(&ltcp_context)`
- or start blocking proc `ltcp_loop(&ltcp_context)` (basically infinite loop of `ltcp_poll(&ltcp_context)`)