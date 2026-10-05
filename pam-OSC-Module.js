// pam-OSC. It allows to controll GrandMA3 with Midi Devices over Open Stage Controll and allows for Feedback from MA.
// Copyright (C) 2024  xxpasixx

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// Display colors per MIDI device, indexed by display slot 0-7
var colors = {};
// Meter levels (0-13) and overload LED states per MIDI device, indexed by strip 0-7
var meters = {};
var meterOverloads = {};
// Sequence and cue names per MIDI device, indexed by display slot 0-7
var names = {};
// Executor fader positions (pitch values) per MIDI device, indexed by pitch channel
var execFaders = {};
// Attribute fader state per MIDI device: last values (percent or "-") from MA and touched faders, by pitch channel
var attributeFaders = {};
var deskLocked = false;
// Whether a command is being typed in MA's command line (reported by the MA plugin)
var cmdLineActive = false;
// Last button state ("On"/"Off") and fader value (0-127) reported by MA per executor
var buttonStates = {};
var execFaderValues = {};

const utils = require("./utils.js");
const colorUtils = require("./colorUtils.js");
const routingUtils = require("./routingUtils.js");
const midiUtils = require("./midiUtils.js");
const oscUtils = require("./oscUtils.js");

var routing = {};

let encoderFine = false;
let encoderRough = false;
let currentAttribute = "dimmer";
let timecode = {
  selectedSlot: 0,
  slots: {},
};

var prefix = "";
var page = "1";

const ipPort = ("" + settings.read("send")).split(":");
const ip = ipPort[0];
const oscPort = ipPort[1];

settings.read("midi").forEach((deviceMidi) => {
  const name = deviceMidi.split(":")[0];
  const fileName = name + ".json";


  const value = loadJSON("mappings/" + fileName, (e) =>
    console.error(
      "The Mapping " +
        fileName +
        " could not be found. Please make sure it exists, or rename your MIDI Device name to a existing one"
    )
  );
  value.buttonFeedbackMapper = eval("(" + value.buttonFeedbackMapper + ")");
  for (let note in value.note) {
    if (!value.note[note].buttonFeedbackMapper) {
      continue;
    }
    value.note[note].buttonFeedbackMapper = eval("(" + value.note[note].buttonFeedbackMapper + ")");
  }
  routing[name] = value;
});

// Start every device on its first encoder page
for (let device of Object.keys(routing)) {
  const firstPage = Object.keys(routing[device].note).find((note) => routing[device].note[note].local == "encoderPage");
  if (firstPage) {
    setEncoderPage(device, firstPage);
    midiUtils.sendEncoderPageLED(routing, device);
  }
}

midiUtils.sendAttributeLED(routing, currentAttribute);
midiUtils.sendPermanentFeedback(routing);

for (let device of Object.keys(routing)) {
  if (routing[device].enableTimecodeSend) {
    midiUtils.resetSegments(routing, device);
    midiUtils.sendSegment(routing, device, 1, timecode.selectedSlot);
  }
}

setTimeout(function () {
  oscUtils.triggerForceReload(ip, oscPort, prefix);
  // Stop attribute value reports left over from an earlier session
  requestAttributeValues();
}, 500);

// MC meters and their overload LEDs fall back on their own, so they have to be resent continuously
setInterval(function () {
  for (let device of Object.keys(meters)) {
    meters[device].forEach((level, strip) => {
      if (level > 0) midiUtils.sendMeter(device, strip, level);
      if ((meterOverloads[device] || [])[strip]) midiUtils.sendMeter(device, strip, midiUtils.METER_OVERLOAD_ON);
    });
  }
}, 100);

// While the encoder labels are shown (attribute mode), a control's "attributeMode" overrides its settings
function getActiveConfig(device, config) {
  return routing[device].encoderLabels && config.attributeMode ? { ...config, ...config.attributeMode } : config;
}

// Assigns the attributes of an encoder page button to the device's attribute encoders, in MIDI CC order
function setEncoderPage(device, pageNote) {
  const attributes = routing[device].note[pageNote].attributes || [];
  const rltvControl = routing[device].rltvControl || {};
  Object.keys(rltvControl)
    .filter((ctrl) => rltvControl[ctrl].attributeMode && "attribute" in rltvControl[ctrl].attributeMode)
    .forEach((ctrl, i) => {
      rltvControl[ctrl].attributeMode.attribute = attributes[i] || null;
    });
  routing[device].encoderPage = "" + pageNote;
}

// MC LED ring value in spread mode (0x30 + width 1-6, lighting 1, 3, 5 ... 11 LEDs from the top center): all LEDs
const RING_ATTRIBUTE = 0x36;

// LED rings of encoders with an attribute mode: lit if they have an attribute in attribute mode, the executor level otherwise
function showEncoderRings(device) {
  const rltvControl = routing[device].rltvControl || {};
  for (let ctrl of Object.keys(rltvControl)) {
    const { attributeMode, returnChannel, returnFrom, returnTo, currValue } = rltvControl[ctrl];
    if (!attributeMode || !returnChannel) continue;
    const value = routing[device].encoderLabels
      ? attributeMode.attribute ? RING_ATTRIBUTE : 0
      : Math.round(utils.mapValue(currValue || 0, 0, 127, returnFrom, returnTo));
    send("midi", device, "/control", 1, returnChannel, value);
  }
}

// Writes both lines (7 characters each) of an LCD
function sendDisplay(device, slot, upper, lower) {
  const lines = [
    [slot * 7, upper],
    [56 + slot * 7, lower],
  ];
  lines.forEach(([offset, text]) => {
    send(
      "midi",
      device,
      "/sysex",
      "f0 00 00 66 " + getMcDeviceId(device) + " 12 " + utils.numberIntoHex(offset) + " " +
        utils.stringToAsciiHex((text + "       ").substring(0, 7)) + "f7"
    );
  });
}

// Sets the LCD background colors, one MC color id ("00" = off ... "07" = white) per slot
function sendDisplayColors(device, colorIds) {
  send("midi", device, "/sysex", "F0 00 00 66 " + getMcDeviceId(device) + " 72 " + colorIds.join(" ") + " F7");
}

// Upper line: the encoder page selected by the button below, lower line: attribute of each encoder
function showEncoderLabels(device) {
  const notes = routing[device].note;
  const pageNotes = Object.keys(notes).filter((note) => notes[note].local == "encoderPage");
  const page = notes[routing[device].encoderPage];
  const labels = page.labels || page.attributes || [];
  for (let slot = 0; slot < 8; slot++) {
    const pageBelow = notes[pageNotes[slot]] || {};
    sendDisplay(device, slot, pageBelow.name || "", labels[slot] || "");
  }
  sendDisplayColors(device, new Array(8).fill("07"));
}

function showExecNames(device) {
  for (let slot = 0; slot < 8; slot++) {
    const [upper, lower] = (names[device] || [])[slot] || ["", ""];
    sendDisplay(device, slot, upper, lower);
  }
  showExecColors(device);
}

function showExecColors(device) {
  if (!colors[device]) return;
  sendDisplayColors(
    device,
    colors[device].map((colorString) => colorUtils.findNearestDisplayColor(colorUtils.parseColorString(colorString)))
  );
}

function enterAttributeMode(device, pageNote) {
  setEncoderPage(device, pageNote);
  routing[device].encoderLabels = true;
  showEncoderLabels(device);
  showEncoderRings(device);
  showExecButtonLEDs(device);
  if (isAttributeFaderMode(device)) {
    // Values of the new attributes come from MA; until then they are unknown
    const state = getAttributeFaderState(device);
    state.values = {};
    for (let channel = 1; channel <= 8; channel++) moveAttributeFader(device, channel);
  }
  requestAttributeValues();
}

function leaveAttributeMode(device) {
  routing[device].encoderLabels = false;
  showExecNames(device);
  showEncoderRings(device);
  showExecButtonLEDs(device);
  for (let channel of Object.keys(execFaders[device] || {})) {
    send("midi", device, "/pitch", parseInt(channel), execFaders[device][channel]);
  }
  requestAttributeValues();
}

// LEDs of executor buttons with an attribute mode: off in attribute mode, the executor state otherwise
function showExecButtonLEDs(device) {
  const notes = routing[device].note;
  for (let midiNote of Object.keys(notes)) {
    const note = notes[midiNote];
    if (!note.exec || !note.attributeMode) continue;
    const active = getActiveConfig(device, note).exec;
    const value = active ? note.permanentFeedback || buttonStates[note.exec] || "Off" : "Off";
    const midiChannel = note.midiChannel || routing[device].midiChannel || 1;
    midiUtils.sendNoteResponse(routing, device, parseInt(midiNote), value, note.buttonFeedbackMapper, midiChannel);
  }
}

// In attribute mode, devices with "attributeModeFaders" use their faders like their encoders
function isAttributeFaderMode(device) {
  return !!(routing[device].encoderLabels && routing[device].attributeModeFaders);
}

// Attributes of the attribute encoders, in MIDI CC order; fader n (pitch channel) uses the n-th one
function getFaderAttributes(device) {
  const rltvControl = routing[device].rltvControl || {};
  return Object.keys(rltvControl)
    .filter((ctrl) => rltvControl[ctrl].attributeMode && "attribute" in rltvControl[ctrl].attributeMode)
    .map((ctrl) => rltvControl[ctrl].attributeMode.attribute);
}

// Tells the MA plugin which attribute values to report (of the first selected fixture), "" for none
function requestAttributeValues() {
  const device = Object.keys(routing).find(isAttributeFaderMode);
  const attributes = device ? getFaderAttributes(device).map((attribute) => attribute || "-").join(";") : "";
  send(ip, oscPort, prefix + "/cmd", {
    type: "s",
    value: 'SetGlobalVariable "pamOscAttributes" "' + attributes + '"',
  });
}

function getAttributeFaderState(device) {
  if (!attributeFaders[device]) attributeFaders[device] = { values: {}, touched: {}, releaseTimers: {}, throttles: {} };
  return attributeFaders[device];
}

// Moves a fader to the attribute value reported by MA, unless it is being touched;
// faders without attribute go down, faders whose value MA can't report stay where they are
function moveAttributeFader(device, channel) {
  const state = getAttributeFaderState(device);
  if (state.touched[channel]) return;
  if (!getFaderAttributes(device)[channel - 1]) {
    send("midi", device, "/pitch", channel, 0);
    return;
  }
  const percent = parseFloat(state.values[channel]);
  if (isNaN(percent)) return;
  send("midi", device, "/pitch", channel, Math.round((percent / 100) * 16380));
}

function setFaderTouch(device, channel, touched) {
  const state = getAttributeFaderState(device);
  clearTimeout(state.releaseTimers[channel]);
  if (touched) {
    state.touched[channel] = true;
    // Touching a fader puts its attribute into the programmer at the current value, like touching it in MA
    const attribute = isAttributeFaderMode(device) && getFaderAttributes(device)[channel - 1];
    const percent = parseFloat(state.values[channel]);
    if (attribute && !isNaN(percent)) {
      sendAttributeFader(device, channel, attribute, (percent / 100) * 16380);
    }
    return;
  }
  // Give MA time to report the final value before the motor follows MA again
  state.releaseTimers[channel] = setTimeout(() => {
    state.touched[channel] = false;
    if (isAttributeFaderMode(device)) moveAttributeFader(device, channel);
  }, 500);
}

// Sends a fader position as attribute value, at most every 50 ms per fader to not flood the command line
function sendAttributeFader(device, channel, attribute, value) {
  const state = getAttributeFaderState(device);
  const throttle = state.throttles[channel] || (state.throttles[channel] = {});
  const percent = Math.round(Math.min(Math.max(value / 16380, 0), 1) * 1000) / 10;
  throttle.pending = 'Attribute "' + attribute + '" At Absolute Percent ' + percent;
  if (throttle.timer) return;

  const flush = () => {
    if (!throttle.pending) {
      throttle.timer = null;
      return;
    }
    send(ip, oscPort, prefix + "/cmd", { type: "s", value: throttle.pending });
    throttle.pending = null;
    throttle.timer = setTimeout(flush, 50);
  };
  flush();
}

// Meters show the fader level of their executor. Levels 0-13 light the green and orange LEDs; the red top
// one is the overload LED, lit at full.
function updateMeters(exec) {
  const value = execFaderValues[exec] || 0;
  const level = Math.round((value / 127) * 13);
  const overload = value >= 126.5;
  routingUtils.getRoutingByMeterId(routing, exec).forEach((mapping) => {
    if (!meters[mapping.device]) meters[mapping.device] = new Array(8).fill(0);
    if (!meterOverloads[mapping.device]) meterOverloads[mapping.device] = new Array(8).fill(false);
    meters[mapping.device][mapping.meterId] = level;
    midiUtils.sendMeter(mapping.device, mapping.meterId, level);
    if (overload != meterOverloads[mapping.device][mapping.meterId]) {
      meterOverloads[mapping.device][mapping.meterId] = overload;
      midiUtils.sendMeter(mapping.device, mapping.meterId, overload ? midiUtils.METER_OVERLOAD_ON : midiUtils.METER_OVERLOAD_OFF);
    }
  });
}

// Mackie Control SysEx device ID: 14 = X-Touch, 15 = X-Touch Extender
function getMcDeviceId(device) {
  return routing[device].mcDeviceId || "14";
}

module.exports = {
  oscInFilter: function (data) {
    var { address, args, host, port } = data;

    if (address === "/status/deskLocked" && args.length > 0) {
      const lockStatus = args[0];
      if (lockStatus.type === 'T') {
        deskLocked = true;
      } else if (lockStatus.type === 'F') {
        deskLocked = false;
      }
      return;
    }

    if (deskLocked && host === "midi") {
      console.log("Desk is locked - blocking OSC event:", address);
      return;
    }

    if (host === "midi") {
      if (address === "/control") {
        var [channel, ctrl, value] = args.map((arg) => arg.value);
        if (routing[port]["control"][ctrl]) {
          send(ip, oscPort, prefix + "/Page" + page + "/Fader" + routing[port]["control"][ctrl], {
            type: "i",
            value: value,
          });
        }

        if (!routing[port]["rltvControl"]) {
          return;
        }
        const rltvControl = routing[port]["rltvControl"][ctrl] && getActiveConfig(port, routing[port]["rltvControl"][ctrl]);

        // handle relative Rotary encoders to act as Absolute
        if (rltvControl && rltvControl.exec) {
          const { exec, currValue, posFrom, posTo, negFrom, negTo } = rltvControl;
        
          // Handle GrandMA encoders Knobs (Playback Section) with relative values 
          if(exec > 300) {
            var relativeValue = utils.getRelativeValue(value, posFrom, posTo, negFrom, negTo);
            send(ip, oscPort, prefix + "/Page" + page + "/Encoder" + exec, {
              type: "i",
              value: relativeValue,
            });
          }

          // Handly others as Faders
          var newValue = currValue + utils.getRelativeValue(value, posFrom, posTo, negFrom, negTo);
          newValue = Math.min(Math.max(newValue, 0), 127) || 0;
          routing[port]["rltvControl"][ctrl].currValue = newValue;

          send(ip, oscPort, prefix + "/Page" + page + "/Fader" + exec, {
            type: "i",
            value: newValue,
          });
        }

        // handle attribute Encoders
        if (rltvControl && rltvControl.attribute) {
          const { attribute, posFrom, posTo, negFrom, negTo, amount } = rltvControl;

          let change = utils.getRelativeValue(value, posFrom, posTo, negFrom, negTo) * amount;
          // Devices with encoder pages set their step size with "amount" and ignore the fine button
          const fine = !routing[port].encoderPage && encoderFine;
          change = fine ? change / 10 : change;
          change = encoderRough ? change * 10 : change;
          change = Math.round(change * 1000) / 1000;
          const plusMinus = change > 0 ? " + " : " - ";
          const attributeToSend = attribute == "current" ? currentAttribute : attribute;
          send(ip, oscPort, prefix + "/cmd", {
            type: "s",
            value: "Attribute " + attributeToSend + " at " + plusMinus + Math.abs(change),
          });
        }
      }
      if (address === "/pitch") {
        var [channel, value] = args.map((arg) => arg.value);
        if (isAttributeFaderMode(port)) {
          const attribute = getFaderAttributes(port)[channel - 1];
          // Only a hand on the fader changes attributes, never the motor following MA
          if (attribute && getAttributeFaderState(port).touched[channel]) {
            sendAttributeFader(port, channel, attribute, value);
            // The X-Touch returns a released fader to the last position it received, so echo it
            getAttributeFaderState(port).values[channel] = "" + (value / 16380) * 100;
            send("midi", port, "/pitch", channel, value);
          }
          return;
        }
        if (!routing[port]["pitch"] || !routing[port]["pitch"][channel]) {
          return;
        }
        const valueMapped = Math.round((value / 16380) * 127);
        send(ip, oscPort, prefix + "/Page" + page + "/Fader" + routing[port]["pitch"][channel], {
          type: "i",
          value: valueMapped,
        });
      }
      if (address === "/note") {
        var [channel, ctrl, value] = args.map((arg) => arg.value);
        var config = routing[port]["note"][ctrl] && getActiveConfig(port, routing[port]["note"][ctrl]);

        if (!config) {
          return;
        }

        if (config.faderTouch) {
          setFaderTouch(port, config.faderTouch, value > 0);
          return;
        }

        if (config.minValue && value <= config.minValue) {
          return;
        }

        if (routing[port].enableTimecodeSend) {
          if (config.timecodeSelect) {
            let slotNum = timecode.selectedSlot;

            slotNum = (slotNum + 1) % 9;

            midiUtils.resetSegments(routing, port);
            midiUtils.sendSegment(routing, port, 1, slotNum);

            if (timecode.slots[slotNum]) midiUtils.updateSegmentsBySlot(routing, timecode.slots[slotNum]);

            timecode.selectedSlot = slotNum;
          }

          if (config.timecodePlayPause && timecode.selectedSlot != 0) {
            const slotNum = timecode.selectedSlot;
            const slot = timecode.slots[slotNum];

            if (value > 0) {
              timecode.btnTimeout = setTimeout(() => {
                slot.running = false;
                slot.cleared = true;

                send(ip, oscPort, "/cmd", {
                  type: "s",
                  value: "Off Timecodeslot " + slotNum,
                });
              }, 500);
            } else {
              clearTimeout(timecode.btnTimeout);

              if (slot?.cleared) {
                slot.cleared = false;
              } else if (slot?.running) {
                slot.running = false;

                send(ip, oscPort, "/cmd", {
                  type: "s",
                  value: "Pause Timecodeslot " + slotNum,
                });
              } else if (slot) {
                slot.running = true;

                send(ip, oscPort, "/cmd", {
                  type: "s",
                  value: "Go+ Timecodeslot " + slotNum,
                });
              }
            }
          }
        }

        // While a command is typed in MA, executor key presses complete it like console keys do (through the MA
        // plugin); releases always go to the executor, so a key held while typing doesn't stay flashed
        if (config.exec && cmdLineActive && value > 0) {
          send(ip, oscPort, prefix + "/cmd", {
            type: "s",
            value: 'SetGlobalVariable "pamOscKey" "' + page + "." + config.exec + '"',
          });
        } else if (config.exec) {
          send(ip, oscPort, prefix + "/Page" + page + "/Key" + config.exec, {
            type: "i",
            value: value,
          });
        }

        if (config.quicKey) {
          send(ip, oscPort, prefix + "/cmd", {
            type: "s",
            value: 'Go+ Quickey "' + config.quicKey + '"',
          });
        }

        if (config.page) {
          // Page and encoder page buttons form one radio group: a page button switches to playback mode
          if (routing[port].encoderLabels) leaveAttributeMode(port);
          midiUtils.sendEncoderPageLED(routing, port);
          // Create the page if it doesn't exist yet, then switch to it; one Lua call keeps both in order
          send(ip, oscPort, prefix + "/cmd", {
            type: "s",
            value:
              'Lua "if not DataPool().Pages[' + config.page + "] then DataPool().Pages:Create(" + config.page +
              ") end; Cmd('Page " + config.page + "')\"",
          });
          // The X-Touch switches a lit LED off when its button is pressed, and MA sends no page update
          // if the page is already selected, so restore the page LEDs ourselves
          setTimeout(() => midiUtils.sendPageLED(routing, page), 100);
        }

        if (config.cmd) {
          send(ip, oscPort, prefix + "/cmd", {
            type: "s",
            value: config.cmd,
          });
        }

        if (config.local) {
          if (config.local == "encoderRough") {
            encoderRough = !encoderRough;
            midiUtils.sendNoteResponse(routing, port, ctrl, encoderRough ? "On" : "Off", null, 1);
          }
          if (config.local == "encoderFine") {
            encoderFine = !encoderFine;
            midiUtils.sendNoteResponse(routing, port, ctrl, encoderFine ? "On" : "Off", null, 1);
          }

          if (config.local == "encoderPage") {
            if (config.featureGroup) {
              send(ip, oscPort, prefix + "/cmd", { type: "s", value: 'FeatureGroup "' + config.featureGroup + '"' });
            }
            enterAttributeMode(port, ctrl);
            midiUtils.sendEncoderPageLED(routing, port);
            midiUtils.sendPageLED(routing, page);
            // The X-Touch switches a lit LED off when its button is pressed
            setTimeout(() => midiUtils.sendEncoderPageLED(routing, port), 100);
          }

          if (config.local == "attribute" && config.attribute) {
            currentAttribute = config.attribute;
            midiUtils.sendAttributeLED(routing, currentAttribute);
          }
        }
      }
      return;
    }

    if (host === ip) {
      const addressSplit = address.split("/");
      const fader = address.substring(address.length - 3, address.length);

      if (addressSplit[2]?.includes("Fader")) {
        const mappingsCtrl = routingUtils.getRoutingByControlerId(routing, fader);
        const mappingsPitch = routingUtils.getRoutingByPitchId(routing, fader);
        const mappingsRltvCtrl = routingUtils.getRoutingByRltvControlerId(routing, fader);

        mappingsCtrl.forEach((mapping) => {
          send("midi", mapping.device, "/control", 1, mapping.midiId, args[0].value);
        });

        mappingsPitch.forEach((mapping) => {
          const valueMapped = Math.round((args[0].value / 127) * 16380);
          if (!execFaders[mapping.device]) execFaders[mapping.device] = {};
          execFaders[mapping.device][mapping.midiId] = valueMapped;
          // In attribute mode the faders show attribute values; they return here when leaving it
          if (isAttributeFaderMode(mapping.device)) return;
          send("midi", mapping.device, "/pitch", mapping.midiId, valueMapped);
        });

        mappingsRltvCtrl.forEach((mapping) => {
          const value = Math.round(utils.mapValue(args[0].value, 0, 127, mapping.from, mapping.to));
          const encoder = routing[mapping.device].rltvControl[mapping.id];
          encoder.currValue = args[0].value;
          // While the encoder controls attributes, its ring shows whether it has one instead
          if (getActiveConfig(mapping.device, encoder) !== encoder) return;
          send("midi", mapping.device, "/control", 1, mapping.midiId, value);
        });

        execFaderValues[fader] = Math.min(Math.max(args[0].value, 0), 127);
        updateMeters(fader);
      }
      if (addressSplit[2]?.includes("Button")) {
        buttonStates[fader] = args[0].value;
        const mappings = routingUtils.getRoutingNoteByExecId(routing, fader);
        mappings.forEach((mapping) => {
          // Executor buttons with an attribute mode stay dark in it; their state is restored when leaving it
          if (mapping.attributeMode && !getActiveConfig(mapping.device, mapping).exec) return;
          const value = mapping.permanentFeedback || args[0].value;
          midiUtils.sendNoteResponse(routing, mapping.device, mapping.midiId, value, mapping.buttonFeedbackMapper, mapping.midiChannel);
        });
      }
      if (address === "/CmdLine") {
        cmdLineActive = args[0].value == 1;
      }
      // MA reports the selected feature group: follow it with the encoder pages of devices in attribute mode
      if (address === "/FeatureGroup") {
        const featureGroup = ("" + args[0].value).toLowerCase();
        for (let device of Object.keys(routing)) {
          if (!routing[device].encoderLabels) continue;
          const notes = routing[device].note;
          const pageNote = Object.keys(notes).find(
            (note) => notes[note].local == "encoderPage" && ("" + notes[note].featureGroup).toLowerCase() == featureGroup
          );
          if (pageNote && pageNote != routing[device].encoderPage) {
            enterAttributeMode(device, pageNote);
            midiUtils.sendEncoderPageLED(routing, device);
          }
        }
      }
      if (address === "/Attributes") {
        const values = ("" + args[0].value).split(";");
        for (let device of Object.keys(routing)) {
          if (!isAttributeFaderMode(device)) continue;
          values.forEach((value, i) => {
            getAttributeFaderState(device).values[i + 1] = value;
            moveAttributeFader(device, i + 1);
          });
        }
      }
      if (address?.includes("/updatePage/current")) {
        page = "" + args[0].value;
        midiUtils.sendPageLED(routing, page);
      }
      if (addressSplit[1]?.includes("masterEnabled")) {
        const mappings = routingUtils.getRoutingNoteByCMD(routing, addressSplit[2]);

        mappings.forEach((mapping) => {
          const value = mapping.permanentFeedback || args[0].value ? "On" : "Off";
          midiUtils.sendNoteResponse(routing, mapping.device, mapping.midiId, value, mapping.buttonFeedbackMapper, mapping.midiChannel);
        });
      }

      if (addressSplit[2]?.includes("Color")) {
        const mappingsDisplay = routingUtils.getRoutingByDisplayId(routing, fader);

        mappingsDisplay.forEach((mapping) => {
          if (!colors[mapping.device]) colors[mapping.device] = new Array(8).fill("0;0;0;0");
          colors[mapping.device][mapping.displayId] = args[0].value;
        });

        new Set(mappingsDisplay.map((mapping) => mapping.device)).forEach((device) => {
          // Keep the colors for later while the encoder labels are shown
          if (!routing[device].encoderLabels) showExecColors(device);
        });
      }

      if (addressSplit[2]?.includes("Name")) {
        const mappingsDisplay = routingUtils.getRoutingByDisplayId(routing, fader);
        // Shorten MA's default names ("Sequence 12") to fit the 7 characters of a line
        const values = args[0].value.replace(/Sequence/g, "Seq.").split(";");

        mappingsDisplay.forEach((mapping) => {
          if (!names[mapping.device]) names[mapping.device] = [];
          names[mapping.device][mapping.displayId] = [values[0] || "", values[1] || ""];

          // Keep the names for later while the encoder labels are shown
          if (!routing[mapping.device].encoderLabels) {
            sendDisplay(mapping.device, mapping.displayId, values[0] || "", values[1] || "");
          }
        });
      }

      for (let device of Object.keys(routing)) {
        if (routing[device].enableTimecodeSend) {
          if (addressSplit[1]?.includes("Timecode")) {
            let slot = addressSplit[1].slice(-1);

            if (!isNaN(slot)) {
              slot = parseInt(slot);

              const time = args[0].value;

              const hrsIndex = time.indexOf("h");
              const minIndex = time.indexOf("m");
              const secIndex = time.indexOf(":");

              const hrs = hrsIndex == -1 ? "0" : time.substring(0, hrsIndex);
              const mins = minIndex == -1 ? "0" : time.substring(hrsIndex + 1, minIndex);
              const secs = time.substring(minIndex + 1, secIndex);
              const mili = time.substring(secIndex + 1);

              const updateChanges = (key, value) => {
                if (!timecode.slots[slot]) timecode.slots[slot] = {};

                if (timecode.slots[slot][key] != value) timecode.slots[slot][key] = value;
              };

              updateChanges("hrs", hrs);
              updateChanges("mins", mins);
              updateChanges("secs", secs);
              updateChanges("mili", mili);

              if (timecode.selectedSlot == slot) {
                midiUtils.updateSegmentsBySlot(routing, timecode.slots[slot]);
              }
            }
          }

          // Check if the message from MA3 contains an address in the timecode slot pool
          if (addressSplit[1]?.startsWith("14.")) {
            const slotNum = addressSplit[1].substring(3);

            if (!isNaN(slotNum) && timecode.slots[slotNum]) {
              timecode.slots[slotNum].running = args[0].value === "Go+";
            }
          }
        }
      }
    }

    return { address, args, host, port };
  },
};
