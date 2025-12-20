%%% @doc GATT Client record definitions

%% ATT Request record - stores all context for a pending ATT operation
-record(att_request, {
    type,           %% discover_services | discover_characteristics | read | write
    from,           %% Pid to reply to
    handle,         %% ATT handle (for read/write)
    conn_handle,    %% Connection handle
    timer_ref,      %% Timeout timer reference
    pdu,            %% ATT PDU binary (for retry)
    retries = 0,    %% Current retry count
    context         %% Type-specific context (maps, accumulators, etc.)
}).
