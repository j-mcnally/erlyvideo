%%% @author     Max Lapshin <max@maxidoors.ru>
%%% @copyright  2009 Max Lapshin
%%% @doc        ems_media handler template
%%% @reference  See <a href="http://erlyvideo.org/" target="_top">http://erlyvideo.org/</a> for more information
%%% @end
%%%
%%%
%%% The MIT License
%%%
%%% Copyright (c) 2010 Max Lapshin
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in
%%% all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%%% THE SOFTWARE.
%%%
%%%---------------------------------------------------------------------------------------
-module(mpegts_media).
-author('Max Lapshin <max@maxidoors.ru>').
-behaviour(ems_media).


-define(D(X), io:format("DEBUG ~p:~p ~p~n",[?MODULE, ?LINE, X])).

-define(MAX_RESTART, 10).
-define(TIMEOUT_RESTART, 1000).

-export([init/1, handle_frame/2, handle_control/2, handle_info/2]).

-record(mpegts, {
  socket,
  options,
  url,
  demuxer,
  make_request,
  restart_count
}).


%%%------------------------------------------------------------------------
%%% Callback functions from ems_media
%%%------------------------------------------------------------------------

%%----------------------------------------------------------------------
%% @spec (Options::list()) -> {ok, State}                   |
%%                            {ok, State, {Format,Storage}} |
%%                            {stop, Reason}
%%
%% @doc Called by ems_media to initialize specific data for current media type
%% @end
%%----------------------------------------------------------------------

init(Options) ->
  URL = proplists:get_value(url, Options),
  MakeRequest = 
  case {proplists:get_value(type, Options),proplists:get_value(make_request, Options, true)} of
    {mpegts_passive, _} -> false;
    {_, true} -> true;
    _ -> false
  end,
  Socket = case MakeRequest of
    true -> connect_http(URL);
    false -> undefined
  end,
  {ok, Reader} = ems_sup:start_mpegts_reader(self()),
  ems_media:set_source(self(), Reader),
  {ok, #mpegts{socket = Socket, demuxer = Reader, options = Options, url = URL, make_request = MakeRequest}}.


  
connect_http(URL) ->
  {_, _, Host, Port, Path, Query} = http_uri:parse(URL),
  {ok, Socket} = gen_tcp:connect(Host, Port, [binary, {packet, line}, {active, false}], 4000),
  ?D({Host, Path, Query, "GET "++Path++" HTTP/1.1\r\nHost: "++Host++":"++integer_to_list(Port)++"\r\nAccept: */*\r\n\r\n"}),
  gen_tcp:send(Socket, "GET "++Path++" HTTP/1.1\r\nHost: "++Host++":"++integer_to_list(Port)++"\r\nAccept: */*\r\n\r\n"),
  ok = inet:setopts(Socket, [{active, once}]),
  Socket.

%%----------------------------------------------------------------------
%% @spec (ControlInfo::tuple(), State) -> {ok, State}       |
%%                                        {ok, State, tick} |
%%                                        {error, Reason}
%%
%% @doc Called by ems_media to handle specific events
%% @end
%%----------------------------------------------------------------------
handle_control({subscribe, _Client, _Options}, State) ->
  %% Subscribe returns:
  %% {ok, State} -> client is subscribed as active receiver
  %% {ok, State, tick} -> client requires ticker (file reader)
  %% {error, Reason} -> client receives {error, Reason}
  {reply, ok, State};

handle_control({source_lost, _Source}, State) ->
  %% Source lost returns:
  %% {ok, State, Source} -> new source is created
  %% {stop, Reason, State} -> stop with Reason
  {stop, source_lost, State};

handle_control({set_source, _Source}, State) ->
  %% Set source returns:
  %% {reply, Reply, State}
  %% {stop, Reason, State}
  {reply, ok, State};

handle_control(_Control, State) ->
  {reply, ok, State}.

%%----------------------------------------------------------------------
%% @spec (Frame::video_frame(), State) -> {ok, Frame, State} |
%%                                        {noreply, State}   |
%%                                        {stop, Reason, State}
%%
%% @doc Called by ems_media to parse frame.
%% @end
%%----------------------------------------------------------------------
handle_frame(Frame, State) ->
  {ok, Frame, State}.


%%----------------------------------------------------------------------
%% @spec (Message::any(), State) ->  {noreply, State}   |
%%                                   {stop, Reason, State}
%%
%% @doc Called by ems_media to parse incoming message.
%% @end
%%----------------------------------------------------------------------
handle_info({http, Socket, {http_response, _Version, 200, _Reply}}, State) ->
  inet:setopts(Socket, [{active, once}]),
  {noreply, State#mpegts{restart_count = undefined}};

handle_info({http, Socket, {http_header, _, _Header, _, _Value}}, State) ->
  inet:setopts(Socket, [{active, once}]),
  {noreply, State};

handle_info({http, Socket, http_eoh}, State) ->
  inet:setopts(Socket, [{active, once}, {packet, raw}]),
  {noreply, State};


handle_info({tcp, Socket, Bin}, #mpegts{demuxer = Reader} = State) when Reader =/= undefined ->
  inet:setopts(Socket, [{active, once}]),
  Reader ! {data, Bin},
  {noreply, State};

handle_info({tcp_closed, Socket}, #mpegts{restart_count = undefined} = State) ->
  handle_info({tcp_closed, Socket}, State#mpegts{restart_count = 0});

handle_info({tcp_closed, _Socket}, #mpegts{url = URL, restart_count = Count, make_request = MakeRequest} = State) ->
  if
    Count > ?MAX_RESTART ->
      {stop, normal, State};
    MakeRequest == false ->
      {noreply, State#mpegts{socket = undefined, restart_count = Count + 1}};
    true ->  
      % FIXME
      % ems_event:stream_source_lost(Media#media_info.host, Media#media_info.name, self()),
      ?D({"Disconnected MPEG-TS socket in mode", Count}),
      timer:sleep(100),
      Socket = connect_http(URL),
      {noreply, State#mpegts{socket = Socket, restart_count = Count + 1}}
  end;

handle_info(Msg, State) ->
  {stop, {unhandled, Msg}, State}.
