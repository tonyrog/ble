%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2025, Tony Rogvall
%%% @doc
%%%    Scan / Find & Control Plejd system nodes
%%% @end
%%% Created : 10 Dec 2025 by Tony Rogvall <tony@rogvall.se>

-module(ble_plejd).

-export([scan/0, scan/1]).
-export([mon/1, mon/2]).

-include_lib("tty/include/tty_boxchar.hrl").
-include("../include/uuid.hrl").

-export([layout/3]).

-define(PLEJD_UUID(I), ?UUID((16#31BA0000+(I)),16#6085,16#4726,16#BE45,16#040C957391B5)).

%% locate Plejd nodes
%% ?PLEJD_UUID(3) == LIGHTLEVEL
%% ?PLEJD_UUID(4) == DATA
%% ?PLEJD_UUID(5) == LAST_DATA
%% ?PLEJD_UUID(9) == AUTH_UUID
%% ?PLEJD_UUID(10) == PING_UUID
%%
%%  
%%
scan() -> 
    scan(#{}).
scan(Options) ->
    {ok, Central} = ble:begin_central(Options),
    Devices = ble:scan(Central, 5000, 
		       %% filter advertised services
		       fun({uuids, UUIDs}) ->
			       lists:member(?PLEJD_UUID(1), UUIDs);
			  (_) ->
			       false
		       end),
    ble:display_devices(Devices),

    %% connect and display 
    lists:foreach(
      fun(Device) ->
	      case ble:discover(Central, Device) of
		  {ok, _Services} ->
		      ok;
		  {error, _} ->
		      ignore
	      end
      end, Devices),

    ble:stop(Central).

-record(plejd,
	{
	 index,
	 props = [],
	 value_handle,
	 value = <<>>
	}).

plejd_data() ->
    [
#plejd{index=2,props=[read,write],value_handle=11},
#plejd{index=4,props=[read,write,notify],value_handle=14},
#plejd{index=3,props=[read,write,indicate],value_handle=18},
#plejd{index=5,props=[read,indicate],value_handle=22},
#plejd{index=6,props=[read,write],value_handle=26},
#plejd{index=7,props=[write],value_handle=29},
#plejd{index=8,props=[read,write,indicate],value_handle=32},
#plejd{index=9,props=[read,write,indicate],value_handle=36},
#plejd{index=10,props=[read,write,indicate],value_handle=40},
#plejd{index=11,props=[read,write,indicate],value_handle=44}
    ].

%%CD:18:0D:85:A5:6F
%%CE:95:BE:E1:AD:3F
%%CF:B3:6D:DA:E8:36  
%%DD:CD:9C:C6:CC:48
%%F8:3E:E1:5C:B0:A4

mon(['1']) ->
    mon("CD:18:0D:85:A5:6F", #{ interface => "hci1" });
mon(['2']) ->
    mon("CE:95:BE:E1:AD:3F", #{ interface => "hci1" });
mon(['3']) ->
    mon("CF:B3:6D:DA:E8:36", #{ interface => "hci1" });
mon(['4']) ->
    mon("DD:CD:9C:C6:CC:48", #{ interface => "hci1" });
mon(['5']) ->
    mon("F8:3E:E1:5C:B0:A4", #{ interface => "hci1" }).


mon(Address, Options) ->
    {ok, Central} = ble:begin_central(Options),
    Device = #{ addr => Address, addr_type => random },
    clearscreen(),
    mon_loop(Central, Device, plejd_data()),
    ble:stop(Central).

mon_loop(Central, Device, Data) ->
    case connect_with_retry(Central, Device, 3) of
        {ok, ConnRef} ->
	    goto_line(1),
            Data1 = read_values(Central, ConnRef, Data, []),
            ble:disconnect(Central, ConnRef),
            timer:sleep(2000),
            mon_loop(Central, Device, Data1);
        {error, Reason} ->
            io:format("Connection failed: ~p, retrying in 5s...~n", [Reason]),
            timer:sleep(5000),
            mon_loop(Central, Device, Data)
    end.

connect_with_retry(_Central, _Device, 0) ->
    {error, max_retries};
connect_with_retry(Central, Device, Retries) ->
    case ble:connect(Central, Device) of
        {ok, ConnRef} ->
            %% Wait a bit and check if connection is still alive
            timer:sleep(200),
            %% Try a simple operation to verify connection
            case ble:read_handle(Central, ConnRef, 11) of
                {ok, _} ->
                    {ok, ConnRef};
                {error, Reason} when Reason =:= timeout; Reason =:= disconnected ->
                    io:format("Connection unstable (~p), retry ~w~n", [Reason, Retries-1]),
                    timer:sleep(500),
                    connect_with_retry(Central, Device, Retries - 1)
            end;
        {error, _} = Error ->
            Error
    end.

%% +-------------------------+
%% |11|  ABCDE               |
%% +--+----------------------+
-define(MAX_DATA_LENGTH, 32).

read_values(Central,ConnRef,[D=#plejd{props=Props,value_handle=VH}|Ds],Acc) ->
    D1 = case lists:member(read, Props) of
	     true ->
		 Value0 = D#plejd.value,
		 case ble:read_handle(Central, ConnRef, VH) of
		     {ok, Value} ->
			 {Len, Data} = format_data(Value,Value0),
			 Data1 = layout(Len,Data,?MAX_DATA_LENGTH),
			 io:format("~tc~2w~tc ~s~tc\n",
				   [?BOX_DRAWINGS_DOUBLE_VERTICAL, 
				    VH, 
				    ?BOX_DRAWINGS_DOUBLE_VERTICAL, 
				    Data1,
				    ?BOX_DRAWINGS_DOUBLE_VERTICAL
				   ]),
			 D#plejd{value=Value};
		     {error, _Reason} ->
			 {Len,Data} = format_data(D#plejd.value),
			 Data1 = layout(Len,Data,?MAX_DATA_LENGTH),
			 io:format("~tc~2w~tc ~s~tc\n",
				   [?BOX_DRAWINGS_DOUBLE_VERTICAL, 
				    VH,
				    ?BOX_DRAWINGS_DOUBLE_VERTICAL, 
				    Data1,
				    ?BOX_DRAWINGS_DOUBLE_VERTICAL
				   ]),
			 D
		 end;
	     false ->
		 io:format("~tc~2w~tc ~*s~tc\n",
			   [?BOX_DRAWINGS_DOUBLE_VERTICAL, 
			    VH,
			    ?BOX_DRAWINGS_DOUBLE_VERTICAL, 
			    -(?MAX_DATA_LENGTH), "N/A",
			    ?BOX_DRAWINGS_DOUBLE_VERTICAL]),
		 D
	 end,
    read_values(Central, ConnRef, Ds, [D1|Acc]);
read_values(_Central, _ConnRef, [], Acc) ->
    lists:reverse(Acc).

%% Len is number of 2 digit hex codes,
%% Data is the list of hex codes
%% MaxLen is number of "characters" to format
%% xx xx xx xx xx  => Len1 = Len*2 + Len-1
layout(0, _Data, MaxLen) ->
    lists:duplicate(MaxLen, $\s);
layout(Len, Data, MaxLen) ->
    CLen = Len*3-1,  %% current actual length
    if CLen =< MaxLen ->
	    Pad = MaxLen - CLen,
	    lists:join($\s, Data) ++ lists:duplicate(Pad, $\s);
       true ->
	    Len1 = (MaxLen-1) div 3, %% stripped down len
	    CLen1 = Len1*3 - 1,
	    Strip = Len - Len1,      %% remove this numbre of items
	    Data1 = lists:sublist(Data, Strip+1, Len1),
	    Pad = MaxLen - CLen1,
	    lists:join($\s, Data1) ++ lists:duplicate(Pad, $\s)
    end.

format_data(B) ->
    Data = format_hex(B),
    {length(Data), Data}.    

format_data(B, B) -> 
    Data = format_hex(B),
    {length(Data), Data};
format_data(B1, <<>>) -> 
    Data = format_hex(B1),
    {length(Data), Data};
format_data(B1, B2) -> 
    %% each item in the Data correspond to one char on screen
    Data = diff_hex(binary_to_list(B1), binary_to_list(B2),[]),
    {length(Data), Data}.
    
diff_hex([B|Bs1],[B|Bs2],Acc) -> 
    diff_hex(Bs1,Bs2,[hex(B)|Acc]);
diff_hex([_B|Bs1],[C|Bs2],Acc) -> 
    diff_hex(Bs1,Bs2,[[inv_sgr(),hex(C),noinv_sgr()]|Acc]);
diff_hex([],[C|Bs2],Acc) -> 
    diff_hex([],Bs2,[[inv_sgr(),hex(C),noinv_sgr()]|Acc]);
diff_hex(_, [],Acc) -> 
    lists:reverse(Acc).

format_hex(Bin) ->
    [hex(B) || <<B>> <= Bin].

hex(X) -> tl(integer_to_list(X+16#100, 16)).

%%
%%  Plejd: "CE:95:BE:E1:AD:3F"
%%
%% Value handle
%% 11(2): <<12>>
%% 14(3): <<>>  LIGHTLEVEL
%% 18(4): <<146,198,25,237,101>>  DATA
%% 22(5): <<158,198,25,237,253,21,29,211,72>> LAST_DATA
%% 26: <<53,169,190,58>>
%% 29: N/A
%% 32: <<153,107,135,226,60,8,219,176>>
%% 36: <<10,243,59,181,22,248,6,74,228,85,173,113,143,184,137,207>> (AUTH_UUID)
%% 40: <<0>> (PING_UUID)
%% 44: <<1,1,42,143,87,136>>
%%
%%  Plejd: "CD:18:0D:85:A5:6F"
%%
%% 11: <<11>>
%% 14: <<>>
%% 18: <<11,121,85,78,159>>
%% 22: <<0,121,85,78,7,71,225,11,222>>
%% 26: <<70,62,152,26>>
%% 29: N/A
%% 32: <<211,222,210,89,100,37,161,135>>
%% 36: <<213,171,86,238,188,88,55,194,143,122,178,113,127,31,27,174>>
%% 40: <<0>>
%% 44: <<0,0>>

-define(ESC,   27).
-define(CSI,   ?ESC,$[).
-define(UP,    $A).
-define(DOWN,  $B).
-define(RIGHT, $C).
-define(LEFT,  $D).
-define(DEL,   $3).
-define(i(N), integer_to_list(N)).

cleareos() -> output(clearos_csi(0)).
clearbos() -> output(clearos_csi(1)).
clearscreen() -> output(clearos_csi(2)).
home() ->    output(home_csi()).
cleareol() -> output(clearol_csi(0)).
clearbol() -> output(clearol_csi(1)).
clearline() -> output(clearol_csi(2)).
goto(R,C) -> output(goto_cs(R,C)).
goto_line(R) -> goto(R, 1).

clearol_csi(I) -> [?CSI,$0+I,$K].
clearos_csi(I) -> [?CSI,$0+I,$J].
    
cleareos_csi() -> [?CSI,$0,$J].
clearbos_csi() -> [?CSI,$1,$J].
clearscreen_csi() -> [?CSI,$2,$J].
home_csi() ->    [?CSI,$H].
cleareol_csi() -> [?CSI,$0,$K].
clearbol_csi() -> [?CSI,$1,$K].
clearline_csi() ->[?CSI,$2,$K].
goto_cs(R,C) -> [?CSI,?i(R),$;,?i(C),$H].

inv_sgr() -> [?CSI,$7,$m].
noinv_sgr() -> [?CSI,$2,$7,$m].
off_sgr() -> [?CSI,$7,$m].
    
output(Chars) ->
    io:put_chars(user, Chars).
