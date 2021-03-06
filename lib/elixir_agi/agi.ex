defmodule ElixirAgi.Agi do
  @moduledoc """
  This module handles the AGI implementation by reading and writing to/from
  the source.

  Copyright 2015 Marcelo Gornstein <marcelog@gmail.com>

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at
      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
  """
  require Logger
  alias ElixirAgi.Agi.Result, as: Result
  use GenServer
  use Behaviour
  defstruct \
    reader: nil,
    io_init: nil,
    io_close: nil,
    writer: nil,
    variables: %{}

  @type t :: ElixirAgi.Agi
  @typep state :: Map.t

  defmacro log(level, message) do
    quote do
      state = var! state
      Logger.unquote(level)("ElixirAgi AGI: #{unquote(message)}")
    end
  end

  @doc """
  Starts and link an AGI application.
  """
  @spec start_link(t) :: GenServer.on_start
  def start_link(info) do
    GenServer.start_link __MODULE__, info
  end

  @doc """
  Starts an AGI application.
  """
  @spec start(t) :: GenServer.on_start
  def start(info) do
    GenServer.start __MODULE__, info
  end

  @doc """
  Closes an AGI socket.
  """
  @spec close(GenServer.server) :: :ok
  def close(server) do
    GenServer.call server, :close
  end

  @doc """
  See: https://wiki.asterisk.org/wiki/display/AST/AGICommand_answer
  """
  @spec answer(GenServer.server) :: Result.t
  def answer(server) do
    exec server, "ANSWER"
  end

  @doc """
  See: https://wiki.asterisk.org/wiki/display/AST/AGICommand_hangup
  """
  @spec hangup(GenServer.server, String.t) :: Result.t
  def hangup(server, channel \\ "") do
    exec server, "HANGUP", [channel]
  end

  @doc """
  See: https://wiki.asterisk.org/wiki/display/AST/Asterisk+13+AGICommand_set+variable
  """
  @spec set_variable(GenServer.server, String.t, String.t) :: Result.t
  def set_variable(server, name, value) do
    GenServer.call(
      server, {:run, "SET", ["VARIABLE", "#{name}", "#{value}"]}
    )
  end

  @doc """
  See: https://wiki.asterisk.org/wiki/display/AST/Asterisk+13+AGICommand_get+full+variable
  """
  @spec get_full_variable(GenServer.server, String.t) :: Result.t
  def get_full_variable(server, name) do
    result = GenServer.call(
      server, {:run, "GET", ["FULL", "VARIABLE", "${#{name}}"]}
    )
    if result.result === "1" do
      [_, var] = Regex.run ~r/\(([^\)]*)\)/, hd(result.extra)
      %Result{result | extra: var}
    else
      %Result{result | extra: nil}
    end
  end

  @doc """
  See: https://wiki.asterisk.org/wiki/display/AST/Application_Dial
  """
  @spec dial(
    GenServer.server, String.t, non_neg_integer(), [String.t]
  ) :: Result.t
  def dial(server, dial_string, timeout_seconds, options) do
    exec server, "DIAL", [
      dial_string, to_string(timeout_seconds), Enum.join(options, ",")
    ]
  end

  @doc """
  See: https://wiki.asterisk.org/wiki/display/AST/AGICommand_exec
  """
  @spec exec(GenServer.server, String.t, [String.t], Integer.t) :: Result.t
  def exec(server, application, args \\ [], timeout \\ 5000) do
    GenServer.call server, {:run, "EXEC", [application|args]}, timeout
  end

  @doc """
  GenServer callback
  """
  @spec init(t) :: {:ok, state}
  def init(info) do
    send self, :read_variables
    :ok = info.io_init.()
    {:ok, %{info: info}}
  end

  @doc """
  GenServer callback
  """
  @spec handle_call(term, term, state) ::
    {:noreply, state} | {:reply, term, state}
  def handle_call(:close, _from, state) do
    {:stop, :normal, :ok, state}
  end

  def handle_call({:run, cmd, args}, _from, state) do
    args = for a <- args, do: ["\"", a, "\" "]
    cmd = ["\"", cmd, "\" "|args]
    :ok = write state.info.writer, cmd
    log :debug, "sending: #{inspect cmd}"
    line = read state.info.reader
    if line === :eof do
      {:stop, :normal, state}
    else
      log :debug, "response: #{line}"
      result = Result.new line
      {:reply, result, state}
    end
  end

  def handle_call(message, _from, state) do
    log :warn, "unknown call: #{inspect message}"
    {:reply, :not_implemented, state}
  end

  @doc """
  GenServer callback
  """
  @spec handle_cast(term, state) :: {:noreply, state} | {:stop, :normal, state}
  def handle_cast(message, state) do
    log :warn, "unknown cast: #{inspect message}"
    {:noreply, state}
  end

  @doc """
  GenServer callback
  """
  @spec handle_info(term, state) :: {:noreply, state}
  def handle_info(:read_variables, state) do
    case read_variables state.info.reader do
      :eof -> {:stop, :normal, state}
      vars ->
        log :debug, "read variables: #{inspect vars}"
        {:ok, _} = :erlang.apply(
          state.info.app_module, :start_link, [self]
        )
        {:noreply, state}
    end
  end

  def handle_info(message, state) do
    log :warn, "unknown message: #{inspect message}"
    {:noreply, state}
  end

  @doc """
  GenServer callback
  """
  @spec code_change(term, state, term) :: {:ok, state}
  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end

  @doc """
  GenServer callback
  """
  @spec terminate(term, state) :: :ok
  def terminate(reason, state) do
    log :info, "terminating with: #{inspect reason}"
    :ok = state.info.io_close.()
    :ok
  end

  defp read_variables(reader, vars \\ %{}) do
    line = read reader
    cond do
      line === :eof -> :eof
      String.length(line) < 2 -> vars
      true ->
        [k, v] = String.split line, ":", parts: 2
        vars = Map.put vars, String.strip(k), String.strip(v)
        read_variables reader, vars
    end
  end

  defp write(writer, data) do
    :ok = writer.([data, "\n"])
    :ok
  end

  defp read(reader) do
    line = reader.()
    {line, _} = String.split_at line, -1
    Logger.debug "AGI: read #{line}"
    case line do
      "HANGUP" <> _rest -> :eof
      _ -> line
    end
  end
end
