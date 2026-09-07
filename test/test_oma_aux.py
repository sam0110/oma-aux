import importlib.machinery
import importlib.util
import pathlib
import unittest
from contextlib import nullcontext
from unittest import mock


HELPER = pathlib.Path(__file__).parents[1] / "bin" / "oma-aux"
LOADER = importlib.machinery.SourceFileLoader("oma_aux", str(HELPER))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
oma_aux = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(oma_aux)


class ChannelPairTests(unittest.TestCase):
    def port(self, port_id, channel=""):
        return {"id": port_id, "channel": channel}

    def test_pairs_stereo_by_channel(self):
        outputs = [self.port(1, "FR"), self.port(2, "FL")]
        inputs = [self.port(3, "FL"), self.port(4, "FR")]
        self.assertEqual(oma_aux.channel_pairs(outputs, inputs), [(2, 3), (1, 4)])

    def test_fans_mono_source_out_to_destination_channels(self):
        outputs = [self.port(1, "MONO")]
        inputs = [self.port(2, "FL"), self.port(3, "FR")]
        self.assertEqual(oma_aux.channel_pairs(outputs, inputs), [(1, 2), (1, 3)])

    def test_falls_back_to_port_order(self):
        outputs = [self.port(1), self.port(2)]
        inputs = [self.port(3), self.port(4)]
        self.assertEqual(oma_aux.channel_pairs(outputs, inputs), [(1, 3), (2, 4)])

    def test_pairs_unnamed_port_after_matching_named_channel(self):
        outputs = [self.port(1, "FL"), self.port(2, "FR")]
        inputs = [self.port(3, "FL"), self.port(4)]
        self.assertEqual(oma_aux.channel_pairs(outputs, inputs), [(1, 3), (2, 4)])


class NormalizeTests(unittest.TestCase):
    def test_exposes_sink_input_and_monitor_as_separate_endpoints(self):
        objects = [
            {
                "id": 10,
                "type": "PipeWire:Interface:Node",
                "info": {"props": {
                    "node.name": "speakers",
                    "node.description": "Speakers",
                    "media.class": "Audio/Sink",
                }},
            },
            {
                "id": 11,
                "type": "PipeWire:Interface:Port",
                "info": {"props": {
                    "node.id": 10,
                    "port.name": "playback_FL",
                    "port.direction": "in",
                    "audio.channel": "FL",
                    "format.dsp": "32 bit float mono audio",
                }},
            },
            {
                "id": 12,
                "type": "PipeWire:Interface:Port",
                "info": {"props": {
                    "node.id": 10,
                    "port.name": "monitor_FL",
                    "port.direction": "out",
                    "audio.channel": "FL",
                    "format.dsp": "32 bit float mono audio",
                }},
            },
        ]

        graph = oma_aux.normalize_graph(objects)

        self.assertEqual(graph["sources"][0]["label"], "Speakers monitor")
        self.assertEqual(graph["sources"][0]["kind"], "monitor")
        self.assertEqual(graph["destinations"][0]["label"], "Speakers")
        self.assertEqual(graph["destinations"][0]["kind"], "device")

    def test_hides_owned_filter_nodes(self):
        objects = [
            {
                "id": 10,
                "type": "PipeWire:Interface:Node",
                "info": {"props": {
                    "node.name": "oma_aux_route_test_input",
                    "media.class": "Audio/Sink",
                }},
            },
            {
                "id": 11,
                "type": "PipeWire:Interface:Port",
                "info": {"props": {
                    "node.id": 10,
                    "port.direction": "in",
                    "audio.channel": "FL",
                }},
            },
        ]
        self.assertEqual(oma_aux.normalize_graph(objects)["destinations"], [])
        self.assertEqual(
            oma_aux.normalize_graph(objects, include_managed=True)["destinations"][0]["id"],
            10,
        )


class FilterTests(unittest.TestCase):
    def test_validates_filter_ranges(self):
        settings = oma_aux.validate_filter({"pan": -0.5, "eq": [1, 2, 3, 4, 5]})
        self.assertEqual(settings, {"pan": -0.5, "eq": [1, 2, 3, 4, 5]})
        with self.assertRaises(SystemExit):
            oma_aux.validate_filter({"pan": 2, "eq": [0, 0, 0, 0, 0]})
        with self.assertRaises(SystemExit):
            oma_aux.validate_filter({"pan": 0, "eq": [0]})

    def test_builds_stereo_pan_and_equalizer_chain(self):
        route = {
            "id": "test",
            "filter": {"pan": -0.25, "eq": [1, 2, 3, 4, 5]},
        }
        arguments, capture, playback = oma_aux.filter_module_arguments(route, "1")
        self.assertIn('"Gain 1" = 1.0000', arguments)
        self.assertIn('"Gain 1" = 0.7500', arguments)
        self.assertIn('label = bq_lowshelf', arguments)
        self.assertIn('label = bq_highshelf', arguments)
        self.assertEqual(capture, "oma_aux_route_test_1_input")
        self.assertEqual(playback, "oma_aux_route_test_1_output")

    def test_builds_runtime_filter_controls(self):
        controls = dict(oma_aux.filter_control_params({
            "pan": 0.25,
            "eq": [1, 2, 3, 4, 5],
        }))
        self.assertEqual(controls["l_gain:Gain 1"], 0.75)
        self.assertEqual(controls["r_gain:Gain 1"], 1.0)
        self.assertEqual(controls["l_eq_2:Gain"], 3)
        self.assertEqual(controls["r_eq_4:Gain"], 5)

    @mock.patch.object(oma_aux.subprocess, "run")
    def test_updates_existing_filter_controls(self, run):
        run.return_value.returncode = 0
        route = {"captureName": "filter_input"}
        graph = {
            "sources": [],
            "destinations": [{"id": 12, "name": "filter_input"}],
            "links": [],
        }
        with (
            mock.patch.object(oma_aux, "pipewire_dump", return_value=[]),
            mock.patch.object(oma_aux, "normalize_graph", return_value=graph),
        ):
            oma_aux.set_filter_controls(
                route, {"pan": -0.5, "eq": [1, 2, 3, 4, 5]}
            )
        command = run.call_args.args[0]
        self.assertEqual(command[:4], ["pw-cli", "set-param", "12", "Props"])
        self.assertIn('"l_gain:Gain 1" 1.0000', command[4])
        self.assertIn('"r_gain:Gain 1" 0.5000', command[4])

    @mock.patch.object(oma_aux, "save_state")
    @mock.patch.object(oma_aux, "set_filter_controls")
    def test_filter_edit_keeps_existing_process(self, set_controls, save_state):
        route = {
            "id": oma_aux.route_id("spotify", "headphones"),
            "sourceName": "spotify",
            "destinationName": "headphones",
            "filter": oma_aux.default_filter(),
            "pid": 123,
        }
        graph = {
            "sources": [{"id": 1, "name": "spotify"}],
            "destinations": [{"id": 2, "name": "headphones"}],
            "links": [],
        }
        state = {"routes": [route]}
        settings = {"pan": 0.5, "eq": [1, 2, 3, 4, 5]}
        with (
            mock.patch.object(oma_aux, "pipewire_dump", return_value=[]),
            mock.patch.object(oma_aux, "normalize_graph", return_value=graph),
            mock.patch.object(oma_aux, "state_lock", return_value=nullcontext()),
            mock.patch.object(oma_aux, "load_state", return_value=state),
            mock.patch.object(oma_aux, "route_process_alive", return_value=True),
            mock.patch.object(oma_aux, "spawn_route_process") as spawn,
            mock.patch.object(oma_aux, "stop_route_process") as stop,
        ):
            oma_aux.set_route_filter(1, 2, settings)
        set_controls.assert_called_once_with(route, settings)
        spawn.assert_not_called()
        stop.assert_not_called()
        self.assertEqual(route["filter"], settings)
        self.assertTrue(route["enabled"])
        save_state.assert_called_once_with(state)

    @mock.patch.object(oma_aux, "save_state")
    @mock.patch.object(oma_aux, "set_filter_controls")
    def test_filter_removal_keeps_existing_process(self, set_controls, save_state):
        route = {
            "id": oma_aux.route_id("spotify", "headphones"),
            "sourceName": "spotify",
            "destinationName": "headphones",
            "filter": {"pan": 0.5, "eq": [1, 2, 3, 4, 5]},
            "enabled": True,
            "pid": 123,
        }
        graph = {
            "sources": [{"id": 1, "name": "spotify"}],
            "destinations": [{"id": 2, "name": "headphones"}],
            "links": [],
        }
        state = {"routes": [route]}
        with (
            mock.patch.object(oma_aux, "pipewire_dump", return_value=[]),
            mock.patch.object(oma_aux, "normalize_graph", return_value=graph),
            mock.patch.object(oma_aux, "state_lock", return_value=nullcontext()),
            mock.patch.object(oma_aux, "load_state", return_value=state),
            mock.patch.object(oma_aux, "route_process_alive", return_value=True),
            mock.patch.object(oma_aux, "activate_route") as activate,
            mock.patch.object(oma_aux, "stop_route_process") as stop,
            mock.patch.object(oma_aux, "connect_endpoint_pair") as connect,
        ):
            oma_aux.clear_route_filter(1, 2)
        set_controls.assert_called_once_with(route, oma_aux.default_filter())
        activate.assert_not_called()
        stop.assert_not_called()
        connect.assert_not_called()
        self.assertEqual(state["routes"], [route])
        self.assertEqual(route["filter"], oma_aux.default_filter())
        self.assertFalse(route["enabled"])
        save_state.assert_called_once_with(state)

    def test_snapshot_exposes_bypassed_route_as_unfiltered(self):
        route = {
            "id": oma_aux.route_id("spotify", "headphones"),
            "sourceName": "spotify",
            "destinationName": "headphones",
            "filter": oma_aux.default_filter(),
            "enabled": False,
            "status": "connected",
        }
        graph = {
            "sources": [{"id": 1, "key": "spotify:out", "name": "spotify"}],
            "destinations": [{
                "id": 2, "key": "headphones:in", "name": "headphones"
            }],
            "links": [],
        }
        with (
            mock.patch.object(oma_aux, "reconcile_routes", return_value={"routes": [route]}),
            mock.patch.object(oma_aux, "pipewire_dump", return_value=[]),
            mock.patch.object(oma_aux, "normalize_graph", return_value=graph),
        ):
            snapshot = oma_aux.graph_snapshot()
        self.assertFalse(snapshot["routes"][0]["filtered"])


class ToggleTests(unittest.TestCase):
    def graph(self, links):
        return {
            "sources": [{"id": 1, "ports": [
                {"id": 11, "channel": "FL"}, {"id": 12, "channel": "FR"}
            ]}],
            "destinations": [{"id": 2, "ports": [
                {"id": 21, "channel": "FL"}, {"id": 22, "channel": "FR"}
            ]}],
            "links": links,
        }

    @mock.patch.object(oma_aux, "run_pw_link")
    def test_toggle_completes_partial_route(self, run_pw_link):
        links = [{
            "id": 30, "outputNode": 1, "inputNode": 2,
            "outputPort": 11, "inputPort": 21,
        }]
        with (
            mock.patch.object(oma_aux, "pipewire_dump", return_value=[]),
            mock.patch.object(oma_aux, "normalize_graph", return_value=self.graph(links)),
            mock.patch.object(oma_aux, "state_lock", return_value=nullcontext()),
            mock.patch.object(oma_aux, "load_state", return_value={"routes": []}),
        ):
            oma_aux.toggle_nodes(1, 2)
        run_pw_link.assert_called_once_with("-L", "12", "22")

    @mock.patch.object(oma_aux, "run_pw_link")
    def test_toggle_disconnects_complete_route(self, run_pw_link):
        links = [
            {"id": 30, "outputNode": 1, "inputNode": 2,
             "outputPort": 11, "inputPort": 21},
            {"id": 31, "outputNode": 1, "inputNode": 2,
             "outputPort": 12, "inputPort": 22},
        ]
        with (
            mock.patch.object(oma_aux, "pipewire_dump", return_value=[]),
            mock.patch.object(oma_aux, "normalize_graph", return_value=self.graph(links)),
            mock.patch.object(oma_aux, "state_lock", return_value=nullcontext()),
            mock.patch.object(oma_aux, "load_state", return_value={"routes": []}),
        ):
            oma_aux.toggle_nodes(1, 2)
        self.assertEqual(
            run_pw_link.call_args_list,
            [mock.call("-d", "30"), mock.call("-d", "31")],
        )


if __name__ == "__main__":
    unittest.main()
