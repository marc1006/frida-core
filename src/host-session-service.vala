namespace Frida {
	public class HostSessionService : Object {
		private Gee.ArrayList<HostSessionBackend> backends = new Gee.ArrayList<HostSessionBackend> ();

		public signal void provider_available (HostSessionProvider provider);
		public signal void provider_unavailable (HostSessionProvider provider);

		public HostSessionService.with_default_backends () {
			add_local_backends ();
#if !LINUX
			add_backend (new FruityHostSessionBackend ());
#endif
			add_backend (new TcpHostSessionBackend ());
		}

		public HostSessionService.with_local_backend_only () {
			add_local_backends ();
		}

		public HostSessionService.with_tcp_backend_only () {
			add_backend (new TcpHostSessionBackend ());
		}

		private void add_local_backends () {
#if LINUX
			add_backend (new LinuxHostSessionBackend ());
#endif
#if DARWIN
			add_backend (new DarwinHostSessionBackend ());
#endif
#if WINDOWS
			add_backend (new WindowsHostSessionBackend ());
#endif
		}

		public async void start () {
			foreach (var backend in backends)
				yield backend.start ();
		}

		public async void stop () {
			foreach (var backend in backends)
				yield backend.stop ();
		}

		public void add_backend (HostSessionBackend backend) {
			backends.add (backend);
			backend.provider_available.connect ((provider) => {
				provider_available (provider);
			});
			backend.provider_unavailable.connect ((provider) => {
				provider_unavailable (provider);
			});
		}

		public void remove_backend (HostSessionBackend backend) {
			backends.remove (backend);
		}
	}

	public interface HostSessionProvider : Object {
		public abstract string name {
			get;
		}

		public abstract ImageData? icon {
			get;
		}

		public abstract HostSessionProviderKind kind {
			get;
		}

		public abstract async HostSession create () throws IOError;

		public abstract async AgentSession obtain_agent_session (AgentSessionId id) throws IOError;
		public signal void agent_session_closed (AgentSessionId id, Error? error);
	}

	public enum HostSessionProviderKind {
		LOCAL_SYSTEM,
		LOCAL_TETHER,
		REMOTE_SYSTEM
	}

	public interface HostSessionBackend : Object {
		public signal void provider_available (HostSessionProvider provider);
		public signal void provider_unavailable (HostSessionProvider provider);

		public abstract async void start ();
		public abstract async void stop ();
	}

	public abstract class BaseDBusHostSession : Object, HostSession {
		public signal void agent_session_closed (AgentSessionId id, Error? error);

		public bool forward_agent_sessions {
			get;
			set;
		}

		private const string LISTEN_ADDRESS_TEMPLATE = "tcp:host=127.0.0.1,port=%u";
		private const uint DEFAULT_AGENT_PORT = 27043;
		private uint last_agent_port = DEFAULT_AGENT_PORT;
		private Gee.ArrayList<Entry> entries = new Gee.ArrayList<Entry> ();

		public virtual async void close () {
			foreach (var entry in entries.slice (0, entries.size))
				yield entry.close ();
			entries.clear ();
		}

		public abstract async HostProcessInfo[] enumerate_processes () throws IOError;

		public abstract async uint spawn (string path, string[] argv, string[] envp) throws IOError;

		public abstract async void resume (uint pid) throws IOError;

		public abstract async void kill (uint pid) throws IOError;

		public async Frida.AgentSessionId attach_to (uint pid) throws IOError {
			foreach (var e in entries) {
				if (e.pid == pid)
					return e.id;
			}

			Object transport;
			var stream = yield perform_attach_to (pid, out transport);

			var cancellable = new Cancellable ();
			var cancelled = new IOError.CANCELLED ("");
			var timeout_source = new TimeoutSource (2000);
			timeout_source.set_callback (() => {
				cancellable.cancel ();
				return false;
			});
			timeout_source.attach (MainContext.get_thread_default ());

			DBusConnection connection;
			AgentSession session;
			try {
				connection = yield DBusConnection.new (stream, null, DBusConnectionFlags.NONE, null, cancellable);
				session = yield connection.get_proxy (null, ObjectPath.AGENT_SESSION, DBusProxyFlags.NONE, cancellable);
			} catch (Error establish_error) {
				if (establish_error is IOError && establish_error.code == cancelled.code)
					throw new IOError.TIMED_OUT ("timed out");
				else
					throw new IOError.FAILED (establish_error.message);
			}
			if (cancellable.is_cancelled ())
				throw new IOError.TIMED_OUT ("timed out");

			timeout_source.destroy ();

			uint port;
			if (forward_agent_sessions) {
				port = DEFAULT_AGENT_PORT;
				bool found_available = false;
				var loopback = new InetAddress.loopback (SocketFamily.IPV4);
				var address_in_use = new IOError.ADDRESS_IN_USE ("");
				while (!found_available) {
					bool used_by_us = false;
					foreach (var existing_entry in entries) {
						if (existing_entry.id.handle == port) {
							used_by_us = true;
							break;
						}
					}
					if (used_by_us) {
						port++;
					} else {
						try {
							var socket = new Socket (SocketFamily.IPV4, SocketType.STREAM, SocketProtocol.TCP);
							socket.bind (new InetSocketAddress (loopback, (uint16) port), false);
							socket.close ();
							found_available = true;
						} catch (Error probe_error) {
							if (probe_error.code == address_in_use.code)
								port++;
							else
								found_available = true;
						}
					}
				}
			} else {
				port = last_agent_port++;
			}
			AgentSessionId id = AgentSessionId (port);

			var entry = new Entry (id, pid, transport, connection, session);
			entries.add (entry);
			connection.closed.connect (on_connection_closed);

			if (forward_agent_sessions) {
				try {
					entry.serve (LISTEN_ADDRESS_TEMPLATE.printf (port));
				} catch (Error serve_error) {
					try {
						yield connection.close ();
					} catch (Error cleanup_error) {
					}
					throw new IOError.FAILED (serve_error.message);
				}
			}

			return AgentSessionId (port);
		}

		protected abstract async IOStream perform_attach_to (uint pid, out Object? transport) throws IOError;

		public async AgentSession obtain_agent_session (AgentSessionId id) throws IOError {
			foreach (var entry in entries) {
				if (entry.id.handle == id.handle)
					return entry.agent_session;
			}
			throw new IOError.NOT_FOUND ("no such session");
		}

		private void on_connection_closed (DBusConnection connection, bool remote_peer_vanished, GLib.Error? error) {
			bool closed_by_us = (!remote_peer_vanished && error == null);
			if (closed_by_us)
				return;

			Entry entry_to_remove = null;
			foreach (var entry in entries) {
				if (entry.agent_connection == connection) {
					entry_to_remove = entry;
					break;
				}
			}

			assert (entry_to_remove != null);
			entries.remove (entry_to_remove);
			entry_to_remove.close.begin ();

			agent_session_closed (entry_to_remove.id, error);
		}

		private class Entry : Object {
			public AgentSessionId id {
				get;
				private set;
			}

			public uint pid {
				get;
				private set;
			}

			public Object? transport {
				get;
				private set;
			}

			public DBusConnection agent_connection {
				get;
				private set;
			}

			public AgentSession agent_session {
				get;
				private set;
			}

			private Gee.Promise<bool> close_request;

			private DBusServer server;
			private Gee.ArrayList<DBusConnection> client_connections = new Gee.ArrayList<DBusConnection> ();
			private Gee.HashMap<DBusConnection, uint> registration_id_by_connection = new Gee.HashMap<DBusConnection, uint> ();

			public Entry (AgentSessionId id, uint pid, Object? transport, DBusConnection agent_connection, AgentSession agent_session) {
				this.id = id;
				this.pid = pid;
				this.transport = transport;
				this.agent_connection = agent_connection;
				this.agent_session = agent_session;
			}

			public async void close () {
				if (close_request != null) {
					try {
						yield close_request.future.wait_async ();
					} catch (Gee.FutureError e) {
						assert_not_reached ();
					}
					return;
				}
				close_request = new Gee.Promise<bool> ();

				if (server != null) {
					server.stop ();
					server = null;
				}

				foreach (var connection in client_connections.slice (0, client_connections.size)) {
					try {
						yield connection.close ();
					} catch (Error client_conn_error) {
					}
				}
				client_connections.clear ();
				registration_id_by_connection.clear ();

				agent_session = null;

				try {
					yield agent_connection.close ();
				} catch (Error agent_conn_error) {
				}
				agent_connection = null;

				close_request.set_value (true);
			}

			public void serve (string listen_address) throws Error {
				server = new DBusServer.sync (listen_address, DBusServerFlags.AUTHENTICATION_ALLOW_ANONYMOUS, DBus.generate_guid ());
				server.new_connection.connect ((connection) => {
					connection.closed.connect (on_client_connection_closed);

					try {
						var registration_id = connection.register_object (Frida.ObjectPath.AGENT_SESSION, agent_session);
						registration_id_by_connection[connection] = registration_id;
					} catch (IOError e) {
						printerr ("failed to register object: %s\n", e.message);
						close.begin ();
						return false;
					}

					client_connections.add (connection);
					return true;
				});
				server.start ();
			}

			private void on_client_connection_closed (DBusConnection connection, bool remote_peer_vanished, GLib.Error? error) {
				uint registration_id;
				if (registration_id_by_connection.unset (connection, out registration_id))
					connection.unregister_object (registration_id);
				client_connections.remove (connection);
			}
		}
	}
}
