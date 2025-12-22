%%
%% API towards SerialPin.ino (pin-io over uart)
%%
-module(serial_pin).

-export([start/0]).
-export([stop/1]).
-export([handle_input/2]).
-export([handle_action/2]).
-export([flush/1]).

-define(RMASK, 1).  %% <mask> 8 - bit mask for input pins
-define(WMASK, 2).  %% <mask> 8 - bit mask for output pins (prio over rmask)
-define(WRITE, 3).  %% <value> write command followed by byte with output bits
-define(READ,  4).  %% 
-define(TIMER, 5).  %% <time> 100ms 
-define(EVENT, 6).  %% <mask> 8 - select pins in rmask! 255=all input pins

%%
%%         Pin: 0 1 2 3 4 5 6 7
%% Arduino Pin: 2 3 4 5 6 7 8 13
%%
-define(TRIGGER_PIN, 0).  %% output
-define(BUSY_PIN,    1).  %% busy input
-define(PULSE_PIN,   3).  %% magnet input

-define(MASK(A), (1 bsl (A))).
-define(MASK(A,B), ( (1 bsl (A)) bor (1 bsl (B)) )).
-define(MASK(A,B,C), ( (1 bsl (A)) bor (1 bsl (B)) bor (1 bsl (C)) )).
-define(MASK_NONE, 2#00000000).
-define(MASK_ALL,  2#11111111).

start() ->
    {ok, U} = uart:open("/dev/ttyACM0", [{baud, 9600}, {active, true}]),
    io:format("Uart open\n"),
    uart:send(U, [?RMASK, ?MASK(?BUSY_PIN,?PULSE_PIN)]),
    uart:send(U, [?WMASK, ?MASK(?TRIGGER_PIN)]),
    %% request change event(s) for BUSY and PULSE
    uart:send(U, [?EVENT, ?MASK(?BUSY_PIN,?PULSE_PIN)]),
    {ok,U}.

stop(U) ->
    uart:send(U, [?EVENT, ?MASK_NONE]),
    uart:close(U).

handle_input(_U, B) ->
    case {(B band ?MASK(?BUSY_PIN)) =/= 0,
	  (B band ?MASK(?PULSE_PIN)) =/= 0 } of
	{true, true} -> busy;    %% robot is running
	{true, false} -> busy;   %% robot is running
	{false,true}  -> pulse;  %% train arrived
	{false,false} -> run     %% continue runnning
    end.

%% initiate robot action
handle_action(U, trigger) ->
    uart:send(U, [?WRITE, ?MASK(?TRIGGER_PIN)]), %% WRITE trigger=on
    io:format("trigger=on\n"),
    %% we should wait for robot to start
    receive
	{uart, U, [B1]} when (B1 band ?MASK(?BUSY_PIN)) =/= 0 ->
	    uart:send(U, [?WRITE, ?MASK_NONE]), %% WRITE trigger=off
	    io:format("trigger=off\n")
    after 3000 ->
	    uart:send(U, [?WRITE, ?MASK_NONE]), %% WRITE trigger=off
	    io:format("trigger after timeout=off\n")
    end.


flush(U) ->
    receive
	{uart, U, _} ->
	    flush(U)
    after 0 ->
	    ok
    end.
