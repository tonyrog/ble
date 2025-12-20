%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2025, Tony Rogvall
%%% @doc
%%%    BLE Security Manager Protocol (SMP) Implementation
%%%    Handles pairing, bonding, and key distribution
%%%    Implements both Legacy Pairing and LE Secure Connections (SC)
%%% @end

-module(ble_smp).

-export([
	 handle_smp/4,
	 create_pairing_response/4,
	 %% Legacy Crypto functions (exported for testing)
	 c1/8,
	 s1/3,
	 %% SC Crypto functions (exported for testing)
	 f4/4,
	 f5/5,
	 f6/7,
	 g2/4,
	 aes_cmac/2
	]).

-include("../include/ble_log.hrl").
-include("ble_state.hrl").


%% SMP Command Codes (Bluetooth Core Spec Vol 3, Part H, Section 3)
-define(SMP_PAIRING_REQUEST,        16#01).
-define(SMP_PAIRING_RESPONSE,       16#02).
-define(SMP_PAIRING_CONFIRM,        16#03).
-define(SMP_PAIRING_RANDOM,         16#04).
-define(SMP_PAIRING_FAILED,         16#05).
-define(SMP_ENCRYPTION_INFO,        16#06).
-define(SMP_MASTER_IDENTIFICATION,  16#07).
-define(SMP_IDENTITY_INFO,          16#08).
-define(SMP_IDENTITY_ADDR_INFO,     16#09).
-define(SMP_SIGNING_INFO,           16#0A).
-define(SMP_SECURITY_REQUEST,       16#0B).
-define(SMP_PAIRING_PUBLIC_KEY,     16#0C).
-define(SMP_PAIRING_DHKEY_CHECK,    16#0D).
-define(SMP_PAIRING_KEYPRESS_NOTIF, 16#0E).

%% SMP Pairing Failed Reason Codes
-define(SMP_PASSKEY_ENTRY_FAILED,   16#01).
-define(SMP_OOB_NOT_AVAILABLE,      16#02).
-define(SMP_AUTH_REQUIREMENTS,      16#03).
-define(SMP_CONFIRM_VALUE_FAILED,   16#04).
-define(SMP_PAIRING_NOT_SUPPORTED,  16#05).
-define(SMP_ENCRYPTION_KEY_SIZE,    16#06).
-define(SMP_COMMAND_NOT_SUPPORTED,  16#07).
-define(SMP_UNSPECIFIED_REASON,     16#08).
-define(SMP_REPEATED_ATTEMPTS,      16#09).
-define(SMP_INVALID_PARAMETERS,     16#0A).
-define(SMP_DHKEY_CHECK_FAILED,     16#0B).
-define(SMP_NUMERIC_COMPARISON_FAILED, 16#0C).

%% IO Capabilities
-define(IO_CAP_DISPLAY_ONLY,        16#00).
-define(IO_CAP_DISPLAY_YESNO,       16#01).
-define(IO_CAP_KEYBOARD_ONLY,       16#02).
-define(IO_CAP_NO_INPUT_OUTPUT,     16#03).
-define(IO_CAP_KEYBOARD_DISPLAY,    16#04).

%% Authentication Requirements
-define(AUTH_BONDING,               16#01).
-define(AUTH_MITM,                  16#04).
-define(AUTH_SC,                    16#08).  %% Secure Connections
-define(AUTH_KEYPRESS,              16#10).
-define(AUTH_CT2,                   16#20).  %% h7 function support

%% Key Distribution Flags
-define(KEY_DIST_ENC,               16#01).  %% LTK
-define(KEY_DIST_ID,                16#02).  %% IRK
-define(KEY_DIST_SIGN,              16#04).  %% CSRK
-define(KEY_DIST_LINK,              16#08).  %% Link Key (BR/EDR)

%%====================================================================
%% API
%%====================================================================

%% @doc Handle incoming SMP packet
%% Session is the current smp_session record or undefined
%% Returns {Response, NewSession} or {error, Reason}
-spec handle_smp(Payload::binary(), ConnHandle::integer(),
                 Session::smp_session() | undefined, Addresses::map()) ->
    {ok, smp_session()} |
    {send, binary(), smp_session()} |
    {send_multi, [binary()], smp_session()} |
    {stk_ready, binary(), smp_session()} |
    {sc_ltk_ready, binary(), smp_session()} |
    {ltk, binary(), smp_session()} |
    {error, term()}.
handle_smp(<<Code:8, Data/binary>>, ConnHandle, Session, Addresses) ->
    ?info("SMP: Received command 0x~2.16.0B on handle ~w", [Code, ConnHandle]),
    case Code of
	?SMP_PAIRING_REQUEST ->
	    handle_pairing_request(Data, ConnHandle, Addresses);
	?SMP_PAIRING_RESPONSE ->
	    handle_pairing_response(Data, ConnHandle, Session);
	?SMP_PAIRING_CONFIRM ->
	    handle_pairing_confirm(Data, ConnHandle, Session);
	?SMP_PAIRING_RANDOM ->
	    handle_pairing_random(Data, ConnHandle, Session);
	?SMP_PAIRING_PUBLIC_KEY ->
	    handle_pairing_public_key(Data, ConnHandle, Session);
	?SMP_PAIRING_DHKEY_CHECK ->
	    handle_pairing_dhkey_check(Data, ConnHandle, Session);
	?SMP_ENCRYPTION_INFO ->
	    handle_encryption_info(Data, ConnHandle, Session);
	?SMP_MASTER_IDENTIFICATION ->
	    handle_master_identification(Data, ConnHandle, Session);
	?SMP_IDENTITY_INFO ->
	    handle_identity_info(Data, ConnHandle, Session);
	?SMP_IDENTITY_ADDR_INFO ->
	    handle_identity_addr_info(Data, ConnHandle, Session);
	?SMP_SIGNING_INFO ->
	    handle_signing_info(Data, ConnHandle, Session);
	?SMP_SECURITY_REQUEST ->
	    handle_security_request(Data, ConnHandle, Session);
	?SMP_PAIRING_FAILED ->
	    handle_pairing_failed(Data, ConnHandle, Session);
	_ ->
	    ?warning("SMP: Unsupported command 0x~2.16.0B", [Code]),
	    {error, {unsupported_command, Code}}
    end.

%%====================================================================
%% Internal - Pairing Handlers
%%====================================================================

%% @doc Handle SMP Pairing Request (we are responder/peripheral)
%% Format: Code(1) + IO_Cap(1) + OOB(1) + AuthReq(1) + MaxKeySize(1) +
%%         InitKeyDist(1) + RespKeyDist(1)
handle_pairing_request(<<IOCap:8, OOB:8, AuthReq:8, MaxKeySize:8,
			 InitKeyDist:8, RespKeyDist:8>> = Preq, _ConnHandle, Addresses) ->
    ?info("SMP Pairing Request:"),
    ?info("  IO Capability: ~s", [io_cap_to_string(IOCap)]),
    ?info("  OOB: ~w", [OOB]),
    ?info("  Auth Req: ~s", [auth_req_to_string(AuthReq)]),
    ?info("  Max Key Size: ~w", [MaxKeySize]),
    ?info("  Init Key Dist: ~s", [key_dist_to_string(InitKeyDist)]),
    ?info("  Resp Key Dist: ~s", [key_dist_to_string(RespKeyDist)]),

    %% Check if initiator wants Secure Connections
    SCRequested = (AuthReq band ?AUTH_SC) =/= 0,
    %% Check if initiator wants bonding
    BondingRequested = (AuthReq band ?AUTH_BONDING) =/= 0,

    %% Create pairing response with our capabilities (match initiator's preferences)
    {Pres, PresPayload} = create_pairing_response(MaxKeySize, Addresses,
                                                   SCRequested, BondingRequested),

    %% Get address info from the Addresses map
    %% Initiator is the central (the phone connecting to us)
    %% Responder is us (the peripheral)
    IA = maps:get(peer_addr, Addresses, <<0:48>>),
    RA = maps:get(local_addr, Addresses, <<0:48>>),
    IAT = maps:get(peer_addr_type, Addresses, 0),
    RAT = maps:get(local_addr_type, Addresses, 0),

    %% Generate our random value for confirm calculation
    LocalRand = crypto:strong_rand_bytes(16),

    %% Initialize SMP session (we are responder)
    BaseSession = #smp_session{
        role = responder,
        preq = <<?SMP_PAIRING_REQUEST, Preq/binary>>,  %% Store full PDU
        pres = Pres,
        tk = <<0:128>>,  %% Just Works: TK is zero
        local_rand = LocalRand,
        iat = IAT,
        rat = RAT,
        ia = IA,
        ra = RA,
        sc_mode = SCRequested
    },

    %% If SC mode, generate ECDH keypair
    Session = case SCRequested of
        true ->
            ?info("SMP: Using LE Secure Connections mode"),
            {PublicKey, PrivateKey} = generate_ecdh_keypair(random),
            BaseSession#smp_session{
                local_sk = PrivateKey,
                local_pk = PublicKey,
                nb = LocalRand  %% Use LocalRand as Nb for SC
            };
        false ->
            ?info("SMP: Using Legacy Pairing mode"),
            BaseSession
    end,

    ?info("SMP: Sending Pairing Response"),
    {send, PresPayload, Session};

handle_pairing_request(Data, _ConnHandle, _Addresses) ->
    ?error("SMP: Invalid Pairing Request format: ~p", [Data]),
    {error, invalid_format}.

%% @doc Create SMP Pairing Response
%% Returns {FullPDU, PayloadToSend}
%% Respects initiator's SC and bonding preferences
create_pairing_response(MaxKeySize, _Addresses, SCRequested, BondingRequested) ->
    %% Use simplest pairing mode: Just Works (no MITM, no display/keyboard)
    IOCap = ?IO_CAP_NO_INPUT_OUTPUT,
    OOB = 0,  %% No OOB data
    %% Match initiator's preferences for SC and bonding
    AuthReq = (case SCRequested of true -> ?AUTH_SC; false -> 0 end) bor
              (case BondingRequested of true -> ?AUTH_BONDING; false -> 0 end),
    KeySize = min(MaxKeySize, 16),  %% Use requested size, max 16
    %% Key distribution - only if bonding is requested
    {InitKeyDist, RespKeyDist} = case BondingRequested of
        true -> {?KEY_DIST_ENC, ?KEY_DIST_ENC};  %% Exchange LTKs
        false -> {0, 0}  %% No key distribution for non-bonding
    end,

    ?info("SMP: Creating Pairing Response: SC=~p, Bonding=~p, AuthReq=0x~2.16.0B",
          [SCRequested, BondingRequested, AuthReq]),

    Payload = <<IOCap:8, OOB:8, AuthReq:8, KeySize:8,
                InitKeyDist:8, RespKeyDist:8>>,
    FullPDU = <<?SMP_PAIRING_RESPONSE, Payload/binary>>,

    {FullPDU, FullPDU}.

%% @doc Handle SMP Pairing Response (when we are initiator)
handle_pairing_response(<<IOCap:8, OOB:8, AuthReq:8, MaxKeySize:8,
			  InitKeyDist:8, RespKeyDist:8>>, ConnHandle, Session) ->
    ?info("SMP Pairing Response from handle ~w:", [ConnHandle]),
    ?info("  IO Capability: ~s", [io_cap_to_string(IOCap)]),
    ?info("  OOB: ~w", [OOB]),
    ?info("  Auth Req: ~s", [auth_req_to_string(AuthReq)]),
    ?info("  Max Key Size: ~w", [MaxKeySize]),
    ?info("  Init Key Dist: ~s", [key_dist_to_string(InitKeyDist)]),
    ?info("  Resp Key Dist: ~s", [key_dist_to_string(RespKeyDist)]),

    {ok, Session};

handle_pairing_response(Data, _ConnHandle, _Session) ->
    ?error("SMP: Invalid Pairing Response format: ~p", [Data]),
    {error, invalid_format}.

%% @doc Handle SMP Pairing Public Key (SC mode only)
%% Public key is 64 bytes: X coordinate (32 bytes) || Y coordinate (32 bytes)
handle_pairing_public_key(<<RemotePK:64/binary>>, ConnHandle, Session)
  when Session =/= undefined, Session#smp_session.sc_mode =:= true ->
    ?info("SMP: Received Public Key from handle ~w (64 bytes)", [ConnHandle]),
    <<RemoteX:32/binary, RemoteY:32/binary>> = RemotePK,
    ?info("SMP: Remote PKx (LE) = ~s", [binary_to_hex(RemoteX)]),
    ?info("SMP: Remote PKy (LE) = ~s", [binary_to_hex(RemoteY)]),

    %% Store remote public key
    Session1 = Session#smp_session{remote_pk = RemotePK},

    %% Calculate DHKey using ECDH
    LocalSK = Session1#smp_session.local_sk,
    DHKey = compute_dhkey(LocalSK, RemotePK),
    ?info("SMP: DHKey computed (32 bytes) = ~s", [binary_to_hex(DHKey)]),
    Session2 = Session1#smp_session{dhkey = DHKey},

    %% Send our public key
    LocalPK = Session2#smp_session.local_pk,
    <<LocalX:32/binary, LocalY:32/binary>> = LocalPK,
    ?info("SMP: Sending our Public Key (64 bytes)"),
    ?info("SMP: Local PKx (LE) = ~s", [binary_to_hex(LocalX)]),
    ?info("SMP: Local PKy (LE) = ~s", [binary_to_hex(LocalY)]),

    Response = <<?SMP_PAIRING_PUBLIC_KEY, LocalPK/binary>>,
    ?info("SMP: Waiting for Pairing Confirm from Central..."),

    {send, Response, Session2};

handle_pairing_public_key(Data, ConnHandle, Session) ->
    ?error("SMP: Invalid Public Key: data_size=~w, session=~p, sc_mode=~p",
           [byte_size(Data), Session =/= undefined,
            Session =/= undefined andalso Session#smp_session.sc_mode]),
    {error, {invalid_public_key, ConnHandle}}.

%% @doc Handle SMP Pairing Confirm
%% For Legacy: uses c1 function
%% For SC: uses f4 function
handle_pairing_confirm(<<Mconfirm:16/binary>>, ConnHandle, Session)
  when Session =/= undefined ->
    ?info("SMP: Pairing Confirm from handle ~w", [ConnHandle]),
    ?debug("SMP: Mconfirm = ~p", [Mconfirm]),

    case Session#smp_session.sc_mode of
        true ->
            handle_sc_pairing_confirm(Mconfirm, ConnHandle, Session);
        false ->
            handle_legacy_pairing_confirm(Mconfirm, ConnHandle, Session)
    end;

handle_pairing_confirm(Data, ConnHandle, Session) ->
    ?error("SMP: Invalid Pairing Confirm: data=~p, session=~p", [Data, Session]),
    {error, {invalid_confirm, ConnHandle}}.

%% @doc Handle Legacy Pairing Confirm
handle_legacy_pairing_confirm(Mconfirm, _ConnHandle, Session) ->
    %% Store their confirm value
    Session1 = Session#smp_session{remote_confirm = Mconfirm},

    %% Calculate our confirm value (Sconfirm)
    %% c1(TK, Srand, preq, pres, iat, rat, ia, ra)
    TK = Session1#smp_session.tk,
    Srand = Session1#smp_session.local_rand,
    Preq = Session1#smp_session.preq,
    Pres = Session1#smp_session.pres,
    IAT = Session1#smp_session.iat,
    RAT = Session1#smp_session.rat,
    IA = Session1#smp_session.ia,
    RA = Session1#smp_session.ra,

    Sconfirm = c1(TK, Srand, Preq, Pres, IAT, RAT, IA, RA),
    Session2 = Session1#smp_session{local_confirm = Sconfirm},

    ?info("SMP: Sending Sconfirm (Legacy)"),
    ?debug("SMP: Sconfirm = ~p", [Sconfirm]),

    %% Send our confirm value
    Response = <<?SMP_PAIRING_CONFIRM, Sconfirm/binary>>,
    {send, Response, Session2}.

%% @doc Handle SC Pairing Confirm (Just Works mode)
%% For Just Works: Cb = f4(PKbx, PKax, Nb, 0)
%% We are responder (b), initiator is (a)
handle_sc_pairing_confirm(Mconfirm, _ConnHandle, Session) ->
    %% Store their confirm value (Ca from initiator)
    Session1 = Session#smp_session{remote_confirm = Mconfirm},

    %% For SC Just Works, we store Na after receiving Mrand
    %% For now, just store the confirm and wait for random
    ?info("SMP: Stored Initiator Confirm (SC mode)"),

    {ok, Session1}.

%% @doc Handle SMP Pairing Random
%% For Legacy: verify confirm, calculate STK
%% For SC: verify confirm using f4, then send our confirm+random, calculate keys
handle_pairing_random(<<Mrand:16/binary>>, ConnHandle, Session)
  when Session =/= undefined ->
    ?info("SMP: Pairing Random from handle ~w", [ConnHandle]),
    ?debug("SMP: Mrand = ~p", [Mrand]),

    case Session#smp_session.sc_mode of
        true ->
            handle_sc_pairing_random(Mrand, ConnHandle, Session);
        false ->
            handle_legacy_pairing_random(Mrand, ConnHandle, Session)
    end;

handle_pairing_random(Data, ConnHandle, Session) ->
    ?error("SMP: Invalid Pairing Random: data=~p, handle=~w, session=~p",
           [Data, ConnHandle, Session]),
    {error, {invalid_random, ConnHandle}}.

%% @doc Handle Legacy Pairing Random
handle_legacy_pairing_random(Mrand, _ConnHandle, Session) ->
    %% Verify their confirm value
    TK = Session#smp_session.tk,
    Preq = Session#smp_session.preq,
    Pres = Session#smp_session.pres,
    IAT = Session#smp_session.iat,
    RAT = Session#smp_session.rat,
    IA = Session#smp_session.ia,
    RA = Session#smp_session.ra,

    %% Calculate expected Mconfirm using their Mrand
    ExpectedMconfirm = c1(TK, Mrand, Preq, Pres, IAT, RAT, IA, RA),
    ReceivedMconfirm = Session#smp_session.remote_confirm,

    ?debug("SMP: Expected Mconfirm = ~p", [ExpectedMconfirm]),
    ?debug("SMP: Received Mconfirm = ~p", [ReceivedMconfirm]),

    case ExpectedMconfirm =:= ReceivedMconfirm of
        true ->
            ?info("SMP: Confirm value verified successfully (Legacy)"),

            %% Store their random
            Session1 = Session#smp_session{remote_rand = Mrand},

            %% Calculate STK
            Srand = Session1#smp_session.local_rand,
            STK = s1(TK, Srand, Mrand),
            Session2 = Session1#smp_session{stk = STK},

            ?info("SMP: STK calculated successfully"),
            ?debug("SMP: STK = ~p", [STK]),

            %% Send our random value
            Response = <<?SMP_PAIRING_RANDOM, Srand/binary>>,
            ?info("SMP: Sending Srand"),

            %% Return with STK ready flag
            {stk_ready, Response, Session2};
        false ->
            ?error("SMP: Confirm value mismatch! (Legacy)"),
            ?error("SMP: Expected ~p", [ExpectedMconfirm]),
            ?error("SMP: Received ~p", [ReceivedMconfirm]),
            %% Send pairing failed
            Response = <<?SMP_PAIRING_FAILED, ?SMP_CONFIRM_VALUE_FAILED>>,
            {send, Response, undefined}
    end.

%% @doc Handle SC Pairing Random (Just Works mode)
%% Na is from initiator (Mrand), Nb is ours
%% For Just Works: Ca = f4(PKax, PKbx, Na, 0) where r=0
handle_sc_pairing_random(Na, _ConnHandle, Session) ->
    %% Store Na (initiator's random)
    Session1 = Session#smp_session{na = Na},

    %% Get public key X coordinates (first 32 bytes of 64-byte public keys)
    %% Keys are stored in little-endian, but f4 expects big-endian
    <<PKaxLE:32/binary, _PKayLE:32/binary>> = Session1#smp_session.remote_pk,
    <<PKbxLE:32/binary, _PKbyLE:32/binary>> = Session1#smp_session.local_pk,

    %% Convert to big-endian for f4 function
    PKax = reverse_bytes(PKaxLE),
    PKbx = reverse_bytes(PKbxLE),

    ?debug("SMP SC: PKax (BE) = ~p", [PKax]),
    ?debug("SMP SC: PKbx (BE) = ~p", [PKbx]),

    %% For Just Works, r = 0
    R = 0,

    %% Verify Ca = f4(PKax, PKbx, Na, 0)
    ExpectedCa = f4(PKax, PKbx, Na, R),
    ReceivedCa = Session1#smp_session.remote_confirm,

    ?debug("SMP SC: Expected Ca = ~p", [ExpectedCa]),
    ?debug("SMP SC: Received Ca = ~p", [ReceivedCa]),

    case ExpectedCa =:= ReceivedCa of
        true ->
            ?info("SMP: Initiator Confirm verified successfully (SC)"),

            %% Calculate our confirm: Cb = f4(PKbx, PKax, Nb, 0)
            Nb = Session1#smp_session.nb,
            Cb = f4(PKbx, PKax, Nb, R),
            Session2 = Session1#smp_session{local_confirm = Cb},

            ?info("SMP: Sending Cb and Nb (SC)"),
            ?debug("SMP SC: Cb = ~p", [Cb]),
            ?debug("SMP SC: Nb = ~p", [Nb]),

            %% Send Cb then Nb
            ConfirmPDU = <<?SMP_PAIRING_CONFIRM, Cb/binary>>,
            RandomPDU = <<?SMP_PAIRING_RANDOM, Nb/binary>>,

            %% Calculate MacKey and LTK using f5
            DHKey = Session2#smp_session.dhkey,
            IA = Session2#smp_session.ia,
            RA = Session2#smp_session.ra,
            IAT = Session2#smp_session.iat,
            RAT = Session2#smp_session.rat,

            %% A1 = initiator address with type, A2 = responder address with type
            A1 = <<IAT:8, IA/binary>>,
            A2 = <<RAT:8, RA/binary>>,

            {MacKey, LTK} = f5(DHKey, Na, Nb, A1, A2),
            ?info("SMP: MacKey and LTK calculated (SC)"),
            ?debug("SMP SC: MacKey = ~p", [MacKey]),
            ?debug("SMP SC: LTK = ~p", [LTK]),

            Session3 = Session2#smp_session{mackey = MacKey, sc_ltk = LTK},

            %% Calculate Eb for DHKey check (we'll send this after receiving Ea)
            %% IOcap is from our pairing response (pres), bytes 1-3: IOCap, OOB, AuthReq
            <<_Code:8, IOcapB:8, OOBB:8, AuthReqB:8, _Rest/binary>> = Session3#smp_session.pres,
            IOcapBin = <<AuthReqB:8, OOBB:8, IOcapB:8>>,  %% Reversed order per spec

            Eb = f6(MacKey, Nb, Na, <<0:128>>, IOcapBin, A2, A1),
            Session4 = Session3#smp_session{eb = Eb},
            ?debug("SMP SC: Eb = ~p", [Eb]),

            {send_multi, [ConfirmPDU, RandomPDU], Session4};
        false ->
            ?error("SMP: Confirm value mismatch! (SC)"),
            ?error("SMP: Expected ~p", [ExpectedCa]),
            ?error("SMP: Received ~p", [ReceivedCa]),
            Response = <<?SMP_PAIRING_FAILED, ?SMP_CONFIRM_VALUE_FAILED>>,
            {send, Response, undefined}
    end.

%% @doc Handle SMP DHKey Check (SC mode only)
handle_pairing_dhkey_check(<<Ea:16/binary>>, ConnHandle, Session)
  when Session =/= undefined, Session#smp_session.sc_mode =:= true ->
    ?info("SMP: Received DHKey Check from handle ~w", [ConnHandle]),
    ?debug("SMP SC: Ea = ~p", [Ea]),

    %% Verify Ea
    MacKey = Session#smp_session.mackey,
    Na = Session#smp_session.na,
    Nb = Session#smp_session.nb,
    IA = Session#smp_session.ia,
    RA = Session#smp_session.ra,
    IAT = Session#smp_session.iat,
    RAT = Session#smp_session.rat,

    A1 = <<IAT:8, IA/binary>>,
    A2 = <<RAT:8, RA/binary>>,

    %% IOcap is from initiator's pairing request (preq), bytes 1-3
    <<_Code:8, IOcapA:8, OOBA:8, AuthReqA:8, _Rest/binary>> = Session#smp_session.preq,
    IOcapBin = <<AuthReqA:8, OOBA:8, IOcapA:8>>,  %% Reversed order per spec

    %% Ea = f6(MacKey, Na, Nb, 0, IOcap_a, A1, A2)
    ExpectedEa = f6(MacKey, Na, Nb, <<0:128>>, IOcapBin, A1, A2),

    ?debug("SMP SC: Expected Ea = ~p", [ExpectedEa]),
    ?debug("SMP SC: Received Ea = ~p", [Ea]),

    case ExpectedEa =:= Ea of
        true ->
            ?info("SMP: DHKey Check verified successfully (SC)"),

            %% Store Ea and send our Eb
            Session1 = Session#smp_session{ea = Ea},
            Eb = Session1#smp_session.eb,

            ?info("SMP: Sending Eb (DHKey Check)"),
            Response = <<?SMP_PAIRING_DHKEY_CHECK, Eb/binary>>,

            %% LTK is now ready
            LTK = Session1#smp_session.sc_ltk,
            ?info("SMP: SC Pairing complete! LTK ready."),

            {sc_ltk_ready, Response, Session1#smp_session{stk = LTK}};
        false ->
            ?error("SMP: DHKey Check failed!"),
            ?error("SMP: Expected ~p", [ExpectedEa]),
            ?error("SMP: Received ~p", [Ea]),
            Response = <<?SMP_PAIRING_FAILED, ?SMP_DHKEY_CHECK_FAILED>>,
            {send, Response, undefined}
    end;

handle_pairing_dhkey_check(Data, ConnHandle, Session) ->
    ?error("SMP: Invalid DHKey Check: data=~p, handle=~w, sc_mode=~p",
           [Data, ConnHandle, Session =/= undefined andalso Session#smp_session.sc_mode]),
    {error, {invalid_dhkey_check, ConnHandle}}.

%% @doc Handle SMP Encryption Information (LTK)
%% This is the Long Term Key sent by the peer after encryption is established
handle_encryption_info(<<LTK:16/binary>>, ConnHandle, Session) ->
    ?info("SMP: Received LTK for handle ~w", [ConnHandle]),
    ?debug("LTK: ~p", [LTK]),
    %% Return the LTK to be stored
    {ltk, LTK, Session};

handle_encryption_info(Data, _ConnHandle, _Session) ->
    ?error("SMP: Invalid Encryption Info format: ~p", [Data]),
    {error, invalid_format}.

%% @doc Handle SMP Master Identification (EDIV and Rand)
handle_master_identification(<<EDIV:16/little, Rand:64/little>>, ConnHandle, Session) ->
    ?info("SMP: Master Identification for handle ~w:", [ConnHandle]),
    ?info("  EDIV: ~w", [EDIV]),
    ?info("  Rand: ~w", [Rand]),
    %% Store these with the LTK for future identification
    {master_id, EDIV, Rand, Session};

handle_master_identification(Data, _ConnHandle, _Session) ->
    ?error("SMP: Invalid Master Identification format: ~p", [Data]),
    {error, invalid_format}.

%% @doc Handle SMP Identity Information (IRK)
handle_identity_info(<<IRK:16/binary>>, ConnHandle, Session) ->
    ?info("SMP: Received IRK for handle ~w", [ConnHandle]),
    {irk, IRK, Session};

handle_identity_info(Data, _ConnHandle, _Session) ->
    ?error("SMP: Invalid Identity Info format: ~p", [Data]),
    {error, invalid_format}.

%% @doc Handle SMP Identity Address Information
handle_identity_addr_info(<<AddrType:8, Addr:6/binary>>, ConnHandle, Session) ->
    ?info("SMP: Identity Address for handle ~w:", [ConnHandle]),
    ?info("  Type: ~w", [AddrType]),
    ?info("  Addr: ~p", [Addr]),
    {identity_addr, AddrType, Addr, Session};

handle_identity_addr_info(Data, _ConnHandle, _Session) ->
    ?error("SMP: Invalid Identity Addr Info format: ~p", [Data]),
    {error, invalid_format}.

%% @doc Handle SMP Signing Information (CSRK)
handle_signing_info(<<CSRK:16/binary>>, ConnHandle, Session) ->
    ?info("SMP: Received CSRK for handle ~w", [ConnHandle]),
    {csrk, CSRK, Session};

handle_signing_info(Data, _ConnHandle, _Session) ->
    ?error("SMP: Invalid Signing Info format: ~p", [Data]),
    {error, invalid_format}.

%% @doc Handle SMP Security Request
handle_security_request(<<AuthReq:8>>, ConnHandle, Session) ->
    ?info("SMP: Security Request from handle ~w:", [ConnHandle]),
    ?info("  Auth Req: ~s", [auth_req_to_string(AuthReq)]),
    %% Peer is requesting security - we should initiate pairing
    {security_request, AuthReq, Session};

handle_security_request(Data, _ConnHandle, _Session) ->
    ?error("SMP: Invalid Security Request format: ~p", [Data]),
    {error, invalid_format}.

%% @doc Handle SMP Pairing Failed
handle_pairing_failed(<<Reason:8>>, ConnHandle, _Session) ->
    ?error("SMP: Pairing Failed from handle ~w: ~s",
	   [ConnHandle, pairing_failed_reason(Reason)]),
    {pairing_failed, Reason, undefined};

handle_pairing_failed(Data, _ConnHandle, _Session) ->
    ?error("SMP: Invalid Pairing Failed format: ~p", [Data]),
    {error, invalid_format}.

%%====================================================================
%% ECDH Functions (P-256 / secp256r1)
%%====================================================================

%% Bluetooth SIG Debug Keys (for testing - from Core Spec Vol 3, Part H, Appendix A)
%% These are well-known keys that can be used when both sides are in debug mode
-define(DEBUG_PRIVATE_KEY_BE, <<16#3f,16#49,16#f6,16#d4,16#a3,16#c5,16#5f,16#38,
                                16#74,16#c9,16#b3,16#e3,16#d2,16#10,16#3f,16#50,
                                16#4a,16#ff,16#60,16#7b,16#eb,16#40,16#b7,16#99,
                                16#58,16#99,16#b8,16#a6,16#cd,16#3c,16#1a,16#bd>>).
-define(DEBUG_PUBLIC_X_BE, <<16#20,16#b0,16#03,16#d2,16#f2,16#97,16#be,16#2c,
                             16#5e,16#2c,16#83,16#a7,16#e9,16#f9,16#a5,16#b9,
                             16#ef,16#f4,16#91,16#11,16#ac,16#f4,16#fd,16#db,
                             16#cc,16#03,16#01,16#48,16#0e,16#35,16#9d,16#e6>>).
-define(DEBUG_PUBLIC_Y_BE, <<16#dc,16#80,16#9c,16#49,16#65,16#2a,16#eb,16#6d,
                             16#63,16#32,16#9a,16#bf,16#5a,16#52,16#15,16#5c,
                             16#76,16#63,16#45,16#c2,16#8f,16#ed,16#30,16#24,
                             16#74,16#1c,16#8e,16#d0,16#15,16#89,16#d2,16#8b>>).

%% @doc Generate ECDH keypair for P-256 curve
%% Returns {PublicKeyLE, PrivateKey} where:
%%   PublicKeyLE = 64 bytes (X || Y coordinates, little-endian for BLE transmission)
%%   PrivateKey = 32 bytes
%%
%% Note: BLE SMP uses little-endian byte order for all multi-byte values.
%% Erlang crypto uses big-endian (network byte order).
-spec generate_ecdh_keypair() -> {PublicKeyLE::binary(), PrivateKey::binary()}.
generate_ecdh_keypair() ->
    generate_ecdh_keypair(random).

%% @doc Generate ECDH keypair - use 'debug' for Bluetooth SIG debug keys
generate_ecdh_keypair(debug) ->
    %% Use Bluetooth SIG debug keys for testing
    ?info("SMP ECDH: Using DEBUG keys (for testing only!)"),
    PrivKey = ?DEBUG_PRIVATE_KEY_BE,
    XBE = ?DEBUG_PUBLIC_X_BE,
    YBE = ?DEBUG_PUBLIC_Y_BE,

    %% Convert to little-endian for BLE transmission
    XLE = reverse_bytes(XBE),
    YLE = reverse_bytes(YBE),

    ?debug("SMP ECDH: Debug PrivKey (BE) = ~s", [binary_to_hex(PrivKey)]),
    ?debug("SMP ECDH: Debug PubKey X (BE) = ~s", [binary_to_hex(XBE)]),
    ?debug("SMP ECDH: Debug PubKey Y (BE) = ~s", [binary_to_hex(YBE)]),
    ?debug("SMP ECDH: Debug PubKey X (LE) = ~s", [binary_to_hex(XLE)]),
    ?debug("SMP ECDH: Debug PubKey Y (LE) = ~s", [binary_to_hex(YLE)]),

    {<<XLE/binary, YLE/binary>>, PrivKey};

generate_ecdh_keypair(random) ->
    %% Generate random keypair using Erlang crypto (big-endian)
    {PubKey, PrivKey} = crypto:generate_key(ecdh, secp256r1),

    %% PubKey is in format <<4, X:32/binary, Y:32/binary>> (uncompressed point, big-endian)
    <<4, XBE:32/binary, YBE:32/binary>> = PubKey,

    %% Convert to little-endian for BLE transmission
    XLE = reverse_bytes(XBE),
    YLE = reverse_bytes(YBE),

    ?debug("SMP ECDH: Generated random keypair"),
    ?debug("SMP ECDH: PrivKey (hex) = ~s", [binary_to_hex(PrivKey)]),
    ?debug("SMP ECDH: PubKey X (BE) = ~s", [binary_to_hex(XBE)]),
    ?debug("SMP ECDH: PubKey Y (BE) = ~s", [binary_to_hex(YBE)]),
    ?debug("SMP ECDH: PubKey X (LE for BLE) = ~s", [binary_to_hex(XLE)]),
    ?debug("SMP ECDH: PubKey Y (LE for BLE) = ~s", [binary_to_hex(YLE)]),

    %% Return public key in little-endian (for sending over BLE)
    %% Keep private key as-is (big-endian, as Erlang crypto expects)
    {<<XLE/binary, YLE/binary>>, PrivKey}.

%% @doc Convert binary to hex string for debugging
binary_to_hex(Bin) ->
    lists:flatten([io_lib:format("~2.16.0B", [B]) || <<B>> <= Bin]).

%% @doc Compute DHKey from our private key and peer's public key
%% RemotePK is 64 bytes: X || Y (in little-endian, as per BLE spec)
-spec compute_dhkey(PrivateKey::binary(), RemotePublicKey::binary()) -> binary().
compute_dhkey(PrivateKey, <<XLE:32/binary, YLE:32/binary>>) ->
    %% BLE transmits coordinates in little-endian, but Erlang crypto expects big-endian
    %% Reverse the byte order of each coordinate
    XBE = reverse_bytes(XLE),
    YBE = reverse_bytes(YLE),

    %% Convert to uncompressed point format for crypto module
    RemotePubPoint = <<4, XBE/binary, YBE/binary>>,

    ?debug("SMP ECDH: Remote X (LE) = ~s", [binary_to_hex(XLE)]),
    ?debug("SMP ECDH: Remote Y (LE) = ~s", [binary_to_hex(YLE)]),
    ?debug("SMP ECDH: Remote X (BE) = ~s", [binary_to_hex(XBE)]),
    ?debug("SMP ECDH: Remote Y (BE) = ~s", [binary_to_hex(YBE)]),

    %% Compute shared secret (result is big-endian)
    SharedSecretBE = crypto:compute_key(ecdh, RemotePubPoint, PrivateKey, secp256r1),

    ?debug("SMP ECDH: DHKey (BE) = ~s", [binary_to_hex(SharedSecretBE)]),
    SharedSecretBE.

%% @doc Reverse bytes in a binary (for endianness conversion)
-spec reverse_bytes(binary()) -> binary().
reverse_bytes(Bin) ->
    list_to_binary(lists:reverse(binary_to_list(Bin))).

%%====================================================================
%% AES-CMAC (RFC 4493)
%%====================================================================

%% @doc AES-CMAC with 128-bit key
%% Used by f4, f5, f6 functions
-spec aes_cmac(Key::binary(), Message::binary()) -> binary().
aes_cmac(Key, Message) when byte_size(Key) =:= 16 ->
    %% Generate subkeys K1, K2
    {K1, K2} = aes_cmac_subkeys(Key),

    %% Process message
    MsgLen = byte_size(Message),

    %% Number of blocks (n)
    N = case MsgLen of
        0 -> 1;
        _ -> (MsgLen + 15) div 16
    end,

    %% Check if last block is complete
    LastBlockComplete = (MsgLen > 0) andalso (MsgLen rem 16 =:= 0),

    %% Process all blocks except the last one
    {X, LastBlock} = case N of
        1 ->
            {<<0:128>>, Message};
        _ ->
            PrevBlocks = binary:part(Message, 0, (N-1) * 16),
            Last = binary:part(Message, (N-1) * 16, MsgLen - (N-1) * 16),
            {aes_cmac_chain(Key, <<0:128>>, PrevBlocks), Last}
    end,

    %% Process last block
    Mn = case LastBlockComplete of
        true ->
            crypto:exor(LastBlock, K1);
        false ->
            %% Pad with 10*
            PadLen = 16 - byte_size(LastBlock),
            Padded = <<LastBlock/binary, 16#80:8, 0:((PadLen-1)*8)>>,
            crypto:exor(Padded, K2)
    end,

    %% Final encryption
    aes_128(Key, crypto:exor(X, Mn)).

%% @doc Generate AES-CMAC subkeys K1 and K2
aes_cmac_subkeys(Key) ->
    %% L = AES(K, 0)
    L = aes_128(Key, <<0:128>>),

    %% Rb constant for 128-bit block
    Rb = <<16#00, 16#00, 16#00, 16#00, 16#00, 16#00, 16#00, 16#00,
           16#00, 16#00, 16#00, 16#00, 16#00, 16#00, 16#00, 16#87>>,

    %% K1 = (L << 1) XOR Rb if MSB(L) = 1, else (L << 1)
    K1 = case L of
        <<1:1, _:127>> ->
            crypto:exor(shift_left_128(L), Rb);
        _ ->
            shift_left_128(L)
    end,

    %% K2 = (K1 << 1) XOR Rb if MSB(K1) = 1, else (K1 << 1)
    K2 = case K1 of
        <<1:1, _:127>> ->
            crypto:exor(shift_left_128(K1), Rb);
        _ ->
            shift_left_128(K1)
    end,

    {K1, K2}.

%% @doc Left shift a 128-bit value by 1
shift_left_128(<<X:128>>) ->
    <<(X bsl 1):128>>.

%% @doc Chain AES-CBC-MAC over complete blocks
aes_cmac_chain(_Key, X, <<>>) ->
    X;
aes_cmac_chain(Key, X, <<Block:16/binary, Rest/binary>>) ->
    Y = aes_128(Key, crypto:exor(X, Block)),
    aes_cmac_chain(Key, Y, Rest).

%%====================================================================
%% SMP Crypto Functions - Secure Connections
%% (Bluetooth Core Spec Vol 3, Part H, Section 2.2)
%%====================================================================

%% @doc f4 - Confirm value generation function for SC
%% f4(U, V, X, Z) = AES-CMAC_X(U || V || Z)
%% U, V are 32 bytes (public key X coordinates)
%% X is 16 bytes (random)
%% Z is 1 byte (0 for Just Works)
-spec f4(U::binary(), V::binary(), X::binary(), Z::integer()) -> binary().
f4(U, V, X, Z) when byte_size(U) =:= 32, byte_size(V) =:= 32,
                    byte_size(X) =:= 16, is_integer(Z) ->
    Message = <<U/binary, V/binary, Z:8>>,
    Result = aes_cmac(X, Message),
    ?debug("SMP f4: U=~p", [U]),
    ?debug("SMP f4: V=~p", [V]),
    ?debug("SMP f4: X=~p", [X]),
    ?debug("SMP f4: Z=~w", [Z]),
    ?debug("SMP f4: Result=~p", [Result]),
    Result.

%% @doc f5 - Key generation function for SC
%% Returns {MacKey, LTK}
%% f5(W, N1, N2, A1, A2) produces T, then MacKey and LTK
%% W is 32 bytes (DHKey)
%% N1, N2 are 16 bytes (nonces)
%% A1, A2 are 7 bytes (address type + address)
-spec f5(W::binary(), N1::binary(), N2::binary(),
         A1::binary(), A2::binary()) -> {MacKey::binary(), LTK::binary()}.
f5(W, N1, N2, A1, A2) when byte_size(W) =:= 32, byte_size(N1) =:= 16,
                           byte_size(N2) =:= 16, byte_size(A1) =:= 7,
                           byte_size(A2) =:= 7 ->
    %% SALT for f5 (defined in spec)
    SALT = <<16#6C, 16#88, 16#83, 16#40, 16#41, 16#56, 16#09, 16#0B,
             16#D0, 16#33, 16#E4, 16#52, 16#FC, 16#7A, 16#C6, 16#B8>>,

    %% T = AES-CMAC_SALT(W)
    T = aes_cmac(SALT, W),

    %% keyID = "btle" (ASCII)
    KeyID = <<"btle">>,

    %% Length = 256 (0x0100 in big-endian)
    Length = <<16#01, 16#00>>,

    %% MacKey = AES-CMAC_T(Counter=0 || keyID || N1 || N2 || A1 || A2 || Length)
    MacKey = aes_cmac(T, <<0:8, KeyID/binary, N1/binary, N2/binary,
                          A1/binary, A2/binary, Length/binary>>),

    %% LTK = AES-CMAC_T(Counter=1 || keyID || N1 || N2 || A1 || A2 || Length)
    LTK = aes_cmac(T, <<1:8, KeyID/binary, N1/binary, N2/binary,
                       A1/binary, A2/binary, Length/binary>>),

    ?debug("SMP f5: W=~p", [W]),
    ?debug("SMP f5: N1=~p", [N1]),
    ?debug("SMP f5: N2=~p", [N2]),
    ?debug("SMP f5: A1=~p", [A1]),
    ?debug("SMP f5: A2=~p", [A2]),
    ?debug("SMP f5: T=~p", [T]),
    ?debug("SMP f5: MacKey=~p", [MacKey]),
    ?debug("SMP f5: LTK=~p", [LTK]),

    {MacKey, LTK}.

%% @doc f6 - Check value generation function for SC
%% f6(W, N1, N2, R, IOcap, A1, A2) = AES-CMAC_W(N1 || N2 || R || IOcap || A1 || A2)
%% W is 16 bytes (MacKey)
%% N1, N2 are 16 bytes
%% R is 16 bytes (0 for Just Works)
%% IOcap is 3 bytes
%% A1, A2 are 7 bytes
-spec f6(W::binary(), N1::binary(), N2::binary(), R::binary(),
         IOcap::binary(), A1::binary(), A2::binary()) -> binary().
f6(W, N1, N2, R, IOcap, A1, A2) when byte_size(W) =:= 16, byte_size(N1) =:= 16,
                                     byte_size(N2) =:= 16, byte_size(R) =:= 16,
                                     byte_size(IOcap) =:= 3, byte_size(A1) =:= 7,
                                     byte_size(A2) =:= 7 ->
    Message = <<N1/binary, N2/binary, R/binary, IOcap/binary, A1/binary, A2/binary>>,
    Result = aes_cmac(W, Message),
    ?debug("SMP f6: W=~p", [W]),
    ?debug("SMP f6: N1=~p", [N1]),
    ?debug("SMP f6: N2=~p", [N2]),
    ?debug("SMP f6: R=~p", [R]),
    ?debug("SMP f6: IOcap=~p", [IOcap]),
    ?debug("SMP f6: A1=~p", [A1]),
    ?debug("SMP f6: A2=~p", [A2]),
    ?debug("SMP f6: Result=~p", [Result]),
    Result.

%% @doc g2 - Numeric comparison value generation (for display)
%% g2(U, V, X, Y) = AES-CMAC_X(U || V || Y) mod 10^6
%% Not needed for Just Works, but included for completeness
-spec g2(U::binary(), V::binary(), X::binary(), Y::binary()) -> integer().
g2(U, V, X, Y) when byte_size(U) =:= 32, byte_size(V) =:= 32,
                    byte_size(X) =:= 16, byte_size(Y) =:= 16 ->
    Message = <<U/binary, V/binary, Y/binary>>,
    <<_:96, Result:32>> = aes_cmac(X, Message),
    Result rem 1000000.

%%====================================================================
%% SMP Crypto Functions - Legacy Pairing
%% (Bluetooth Core Spec Vol 3, Part H, Section 2.2)
%%====================================================================

%% @doc c1 - Confirm value generation function (Legacy)
%% c1(k, r, pres, preq, iat, rat, ia, ra) = e(k, e(k, r XOR p1) XOR p2)
%% where:
%%   p1 = pres || preq || rat' || iat'  (128 bits)
%%   p2 = padding || ia || ra           (128 bits)
%%   iat', rat' are the address types as single bytes (padded)
%%
%% Note: All values should be in little-endian byte order as per Bluetooth spec
-spec c1(TK::binary(), R::binary(), Preq::binary(), Pres::binary(),
         IAT::integer(), RAT::integer(), IA::binary(), RA::binary()) -> binary().
c1(TK, R, Preq, Pres, IAT, RAT, IA, RA) when
      byte_size(TK) =:= 16, byte_size(R) =:= 16,
      byte_size(IA) =:= 6, byte_size(RA) =:= 6 ->

    %% Ensure preq and pres are exactly 7 bytes (opcode + 6 bytes data)
    %% They should already include the opcode
    PreqPadded = ensure_7_bytes(Preq),
    PresPadded = ensure_7_bytes(Pres),

    %% p1 = pres || preq || rat || iat (LSB first)
    %% 7 + 7 + 1 + 1 = 16 bytes
    P1 = <<PresPadded/binary, PreqPadded/binary, RAT:8, IAT:8>>,

    %% p2 = padding(4 bytes, 0) || ia(6 bytes) || ra(6 bytes)
    %% 4 + 6 + 6 = 16 bytes
    P2 = <<0:32, IA/binary, RA/binary>>,

    ?debug("SMP c1: TK=~p", [TK]),
    ?debug("SMP c1: R=~p", [R]),
    ?debug("SMP c1: P1=~p", [P1]),
    ?debug("SMP c1: P2=~p", [P2]),

    %% e(k, r XOR p1)
    RxorP1 = crypto:exor(R, P1),
    T = aes_128(TK, RxorP1),

    %% e(k, T XOR p2)
    TxorP2 = crypto:exor(T, P2),
    Result = aes_128(TK, TxorP2),

    ?debug("SMP c1: Result=~p", [Result]),
    Result.

%% @doc s1 - Key generation function for STK (Legacy)
%% s1(k, r1, r2) = e(k, r2' || r1')
%% where r1' and r2' are the least significant 64 bits of r1 and r2
-spec s1(TK::binary(), R1::binary(), R2::binary()) -> binary().
s1(TK, R1, R2) when byte_size(TK) =:= 16,
                    byte_size(R1) =:= 16,
                    byte_size(R2) =:= 16 ->
    %% Take least significant 64 bits (first 8 bytes in little-endian)
    <<R1Low:8/binary, _:8/binary>> = R1,
    <<R2Low:8/binary, _:8/binary>> = R2,

    %% Concatenate r2' || r1'
    R = <<R2Low/binary, R1Low/binary>>,

    ?debug("SMP s1: TK=~p", [TK]),
    ?debug("SMP s1: R1Low=~p, R2Low=~p", [R1Low, R2Low]),
    ?debug("SMP s1: R=~p", [R]),

    Result = aes_128(TK, R),

    ?debug("SMP s1: STK=~p", [Result]),
    Result.

%% @doc AES-128 encryption (e function in spec)
-spec aes_128(Key::binary(), Plaintext::binary()) -> binary().
aes_128(Key, Plaintext) when byte_size(Key) =:= 16, byte_size(Plaintext) =:= 16 ->
    crypto:crypto_one_time(aes_128_ecb, Key, Plaintext, true).

%% @doc Ensure binary is exactly 7 bytes (for preq/pres)
ensure_7_bytes(Bin) when byte_size(Bin) >= 7 ->
    <<Result:7/binary, _/binary>> = Bin,
    Result;
ensure_7_bytes(Bin) ->
    PadLen = 7 - byte_size(Bin),
    <<Bin/binary, 0:(PadLen*8)>>.

%%====================================================================
%% Internal - Helper Functions
%%====================================================================

io_cap_to_string(?IO_CAP_DISPLAY_ONLY) -> "DisplayOnly";
io_cap_to_string(?IO_CAP_DISPLAY_YESNO) -> "DisplayYesNo";
io_cap_to_string(?IO_CAP_KEYBOARD_ONLY) -> "KeyboardOnly";
io_cap_to_string(?IO_CAP_NO_INPUT_OUTPUT) -> "NoInputNoOutput";
io_cap_to_string(?IO_CAP_KEYBOARD_DISPLAY) -> "KeyboardDisplay";
io_cap_to_string(X) -> io_lib:format("Unknown(~w)", [X]).

auth_req_to_string(AuthReq) ->
    Flags = [
	     if AuthReq band ?AUTH_BONDING =/= 0 -> "Bonding"; true -> "" end,
	     if AuthReq band ?AUTH_MITM =/= 0 -> "MITM"; true -> "" end,
	     if AuthReq band ?AUTH_SC =/= 0 -> "SC"; true -> "" end,
	     if AuthReq band ?AUTH_KEYPRESS =/= 0 -> "Keypress"; true -> "" end,
	     if AuthReq band ?AUTH_CT2 =/= 0 -> "CT2"; true -> "" end
	    ],
    string:join([F || F <- Flags, F =/= ""], ", ").

key_dist_to_string(KeyDist) ->
    Flags = [
	     if KeyDist band ?KEY_DIST_ENC =/= 0 -> "LTK"; true -> "" end,
	     if KeyDist band ?KEY_DIST_ID =/= 0 -> "IRK"; true -> "" end,
	     if KeyDist band ?KEY_DIST_SIGN =/= 0 -> "CSRK"; true -> "" end,
	     if KeyDist band ?KEY_DIST_LINK =/= 0 -> "LinkKey"; true -> "" end
	    ],
    string:join([F || F <- Flags, F =/= ""], ", ").

pairing_failed_reason(?SMP_PASSKEY_ENTRY_FAILED) -> "Passkey Entry Failed";
pairing_failed_reason(?SMP_OOB_NOT_AVAILABLE) -> "OOB Not Available";
pairing_failed_reason(?SMP_AUTH_REQUIREMENTS) -> "Authentication Requirements";
pairing_failed_reason(?SMP_CONFIRM_VALUE_FAILED) -> "Confirm Value Failed";
pairing_failed_reason(?SMP_PAIRING_NOT_SUPPORTED) -> "Pairing Not Supported";
pairing_failed_reason(?SMP_ENCRYPTION_KEY_SIZE) -> "Encryption Key Size";
pairing_failed_reason(?SMP_COMMAND_NOT_SUPPORTED) -> "Command Not Supported";
pairing_failed_reason(?SMP_UNSPECIFIED_REASON) -> "Unspecified Reason";
pairing_failed_reason(?SMP_REPEATED_ATTEMPTS) -> "Repeated Attempts";
pairing_failed_reason(?SMP_INVALID_PARAMETERS) -> "Invalid Parameters";
pairing_failed_reason(?SMP_DHKEY_CHECK_FAILED) -> "DHKey Check Failed";
pairing_failed_reason(?SMP_NUMERIC_COMPARISON_FAILED) -> "Numeric Comparison Failed";
pairing_failed_reason(X) -> io_lib:format("Unknown(~w)", [X]).
