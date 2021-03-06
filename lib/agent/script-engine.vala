using Gee;

namespace Frida.Agent {
	public class ScriptEngine : Object {
		public signal void message_from_script (AgentScriptId sid, string message, uint8[] data);
		public signal void message_from_debugger (string message);

		private Gum.MemoryRange agent_range;
		private uint last_script_id = 0;
		private HashMap<uint, ScriptInstance> instance_by_id = new HashMap<uint, ScriptInstance> ();

		public ScriptEngine (Gum.MemoryRange agent_range) {
			this.agent_range = agent_range;
		}

		public async void shutdown () {
			foreach (var instance in instance_by_id.values) {
				yield instance.destroy ();
			}
			instance_by_id.clear ();
		}

		public async ScriptInstance create_script (string? name, string source) throws IOError {
			var sid = AgentScriptId (++last_script_id);

			string script_name;
			if (name != null)
				script_name = name;
			else
				script_name = "script%u".printf (sid.handle);

			var script = yield Gum.Script.from_string (script_name, source);
			script.get_stalker ().exclude (agent_range);
			script.set_message_handler ((script, message, data) => {
				this.message_from_script (sid, message, data);
			});

			var instance = new ScriptInstance (sid, script);
			instance_by_id[sid.handle] = instance;

			return instance;
		}

		public async void destroy_script (AgentScriptId sid) throws IOError {
			ScriptInstance instance;
			if (!instance_by_id.unset (sid.handle, out instance))
				throw new IOError.FAILED ("invalid script id");
			yield instance.destroy ();
		}

		public async void load_script (AgentScriptId sid) throws IOError {
			var instance = instance_by_id[sid.handle];
			if (instance == null)
				throw new IOError.FAILED ("invalid script id");
			yield instance.script.load ();
		}

		public void post_message_to_script (AgentScriptId sid, string message) throws IOError {
			var instance = instance_by_id[sid.handle];
			if (instance == null)
				throw new IOError.FAILED ("invalid script id");
			instance.script.post_message (message);
		}

		public void enable_debugger () throws IOError {
			Gum.Script.set_debug_message_handler (on_debug_message);
		}

		public void disable_debugger () throws IOError {
			Gum.Script.set_debug_message_handler (null);
		}

		public void post_message_to_debugger (string message) {
			Gum.Script.post_debug_message (message);
		}

		private void on_debug_message (string message) {
			message_from_debugger (message);
		}

		public class ScriptInstance : Object {
			public AgentScriptId sid {
				get;
				construct;
			}

			public Gum.Script script {
				get;
				construct;
			}

			public ScriptInstance (AgentScriptId sid, Gum.Script script) {
				Object (sid: sid, script: script);
			}

			public async void destroy () {
				Gum.Stalker stalker = script.get_stalker ();
				yield script.unload ();
				while (stalker.garbage_collect ()) {
					var source = new TimeoutSource (50);
					source.set_callback (() => {
						destroy.callback ();
						return false;
					});
					source.attach (MainContext.get_thread_default ());
					yield;
				}
			}
		}
	}
}
