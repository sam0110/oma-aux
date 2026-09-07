import importlib.machinery
import importlib.util
import pathlib
import unittest
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
        with mock.patch.object(oma_aux, "graph_snapshot", return_value=self.graph(links)):
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
        with mock.patch.object(oma_aux, "graph_snapshot", return_value=self.graph(links)):
            oma_aux.toggle_nodes(1, 2)
        self.assertEqual(
            run_pw_link.call_args_list,
            [mock.call("-d", "30"), mock.call("-d", "31")],
        )


if __name__ == "__main__":
    unittest.main()
