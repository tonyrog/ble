%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2025, Tony Rogvall
%%% @doc
%%%    BLE State Record Definition
%%%    Shared between ble.erl and gatt_client.erl
%%% @end

-ifndef(__BLE_STATE_HRL__).
-define(__BLE_STATE_HRL__, true).

-include_lib("bt/include/uuid.hrl").
%% Type definitions
-type service_type() :: primary | secondary.
-type property() :: read|write|notify|indicate.
-type descriptor() :: term().  %% FIXME
-type handle() :: integer().

-type characteristic() ::
	#{ handle => handle(),
	   uuid => binary(),
	   properties => [property()],
	   value_handle => integer(),
	   value => binary(),
	   descriptors => [descriptor()]
	 }.

-type service() ::
	#{ handle => handle(),
	   uuid => binary(),
	   type => service_type(),
	   characteristics => [handle()]
	 }.

%% Connection record - used for both central and peripheral modes
-record(connection, {
    ref :: reference() | undefined,           %% Connection reference (for API)
    handle :: handle(),                        %% HCI connection handle
    addr :: binary() | undefined,              %% Peer device address
    addr_type :: 0 | 1 | undefined,            %% Peer address type (0=public, 1=random)
    gatt_server :: pid() | undefined,          %% GATT server pid (peripheral mode)
    objects = #{} :: #{handle() => service() | characteristic()},
    uuids = #{} :: #{uuid() => handle()}
}).
-type connection() :: #connection{}.

%% SMP Pairing Session state
-record(smp_session, {
    role :: initiator | responder,
    preq :: binary() | undefined,         %% Pairing Request PDU
    pres :: binary() | undefined,         %% Pairing Response PDU
    tk = <<0:128>> :: binary(),           %% Temporary Key (0 for Just Works)
    local_rand :: binary() | undefined,   %% Our random value (128 bits)
    remote_rand :: binary() | undefined,  %% Peer's random value
    local_confirm :: binary() | undefined, %% Our confirm value
    remote_confirm :: binary() | undefined, %% Peer's confirm value
    iat :: 0 | 1,                         %% Initiator address type
    rat :: 0 | 1,                         %% Responder address type
    ia :: binary() | undefined,           %% Initiator address (6 bytes)
    ra :: binary() | undefined,           %% Responder address (6 bytes)
    stk :: binary() | undefined,          %% Short Term Key (calculated)
    %% Secure Connections fields
    sc_mode = false :: boolean(),         %% true if using SC pairing
    local_sk :: binary() | undefined,     %% Our ECDH private key (32 bytes)
    local_pk :: binary() | undefined,     %% Our ECDH public key (64 bytes: X || Y)
    remote_pk :: binary() | undefined,    %% Peer's ECDH public key (64 bytes)
    dhkey :: binary() | undefined,        %% Calculated DHKey (32 bytes)
    mackey :: binary() | undefined,       %% MAC key from f5 (16 bytes)
    sc_ltk :: binary() | undefined,       %% LTK from f5 for SC (16 bytes)
    na :: binary() | undefined,           %% Initiator's nonce Na (16 bytes)
    nb :: binary() | undefined,           %% Responder's nonce Nb (16 bytes)
    ea :: binary() | undefined,           %% Initiator's DHKey check value
    eb :: binary() | undefined            %% Responder's DHKey check value
}).
-type smp_session() :: #smp_session{}.

%% BLE State Record
-record(ble_state,
	{
	 mode :: peripheral | central,
	 interface :: undefined | string(),
	 hci :: reference(),
	 hci_channel = raw :: raw | user,  %% HCI channel mode
	 device_name :: undefined | string(),
	 %% Our own BD_ADDR (read from HCI or set for advertising)
	 local_addr :: binary() | undefined,
	 local_addr_type = 0 :: 0 | 1,  %% 0=public, 1=random
	 %% For peripheral mode: services we offer
	 services = [] :: [service()],
	 advertising = false :: boolean(),
	 adv_decoder = undefined :: atom(), %% decoder module for manuf data
	 adv_encoder = undefined :: atom(), %% encoder module for manuf data
	 adv_manuf = undefined :: undefined | map(),     %% current manuf data
	 connections = #{} :: #{ handle() => connection()},
	 conn_refs = #{} :: #{ reference() => handle() },
	 %% {Addr, From, TRef} = waiting for connection
	 %% {Addr, From, cancelling} = cancel sent, waiting for LE_CONN_COMPLETE
	 pending_conn = undefined :: undefined | {binary(), pid(), reference()} | {binary(), pid(), cancelling},
	 %% Pending ATT request context
	 pending_att = undefined :: undefined | term(),
	 %% Long Term Keys for bonded devices (handle => LTK)
	 ltk_store = #{} :: #{ handle() => binary() },
	 %% Short Term Keys for current pairing sessions (handle => STK)
	 stk_store = #{} :: #{ handle() => binary() },
	 %% Active SMP pairing sessions (handle => smp_session())
	 smp_sessions = #{} :: #{ handle() => smp_session() },
	 %% Security mode: normal | accept_all | reject_all
	 ltk_mode = normal :: normal | accept_all | reject_all,
	 %% Notification subscribers (UUID => [Callback])
	 %% Callback signature: fun(UUID, Value, Origin) -> ok
	 %% Origin = local | remote
	 subscribers = #{} :: #{ uuid() => [fun((uuid(), binary(), local | remote) -> ok)] },
	 size :: map(),
	 features :: binary(),
	 %% ACL packet reassembly buffer (handle => {ExpectedLen, AccumulatedData})
	 acl_buffer = #{} :: #{ handle() => {non_neg_integer(), binary()} }
	}).
-type ble_state() :: #ble_state{}.

-endif.
