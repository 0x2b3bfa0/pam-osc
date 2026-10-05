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
var deskLocked = false;
// Fader value (0-127) reported by MA per executor
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
        // handle relative Rotary encoders to act as Absolute
        if (routing[port]["rltvControl"][ctrl] && routing[port]["rltvControl"][ctrl].exec) {
          const { exec, currValue, posFrom, posTo, negFrom, negTo } = routing[port]["rltvControl"][ctrl];
        
          // Handle GrandMA encoders Knobs (Playback Section) with relative values 
          if(routing[port]["rltvControl"][ctrl].exec > 300) {
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
        if (routing[port]["rltvControl"][ctrl] && routing[port]["rltvControl"][ctrl].attribute) {
          const { attribute, posFrom, posTo, negFrom, negTo, amount } = routing[port]["rltvControl"][ctrl];

          let change = utils.getRelativeValue(value, posFrom, posTo, negFrom, negTo) * amount;
          change = encoderFine ? change / 10 : change;
          change = encoderRough ? change * 10 : change;
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
        var config = routing[port]["note"][ctrl];

        if (!config) {
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

        if (config.exec) {
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
          send("midi", mapping.device, "/pitch", mapping.midiId, valueMapped);
        });

        mappingsRltvCtrl.forEach((mapping) => {
          const value = Math.round(utils.mapValue(args[0].value, 0, 127, mapping.from, mapping.to));
          routing[mapping.device].rltvControl[mapping.id].currValue = args[0].value;
          send("midi", mapping.device, "/control", 1, mapping.midiId, value);
        });

        execFaderValues[fader] = Math.min(Math.max(args[0].value, 0), 127);
        updateMeters(fader);
      }
      if (addressSplit[2]?.includes("Button")) {
        const mappings = routingUtils.getRoutingNoteByExecId(routing, fader);
        mappings.forEach((mapping) => {
          const value = mapping.permanentFeedback || args[0].value;
          midiUtils.sendNoteResponse(routing, mapping.device, mapping.midiId, value, mapping.buttonFeedbackMapper, mapping.midiChannel);
        });
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
          var midiCommand = "F0 00 00 66 " + getMcDeviceId(device) + " 72 ";
          colors[device].forEach((colorString) => {
            const color = colorUtils.parseColorString(colorString);
            const displayColor = colorUtils.findNearestDisplayColor(color);
            midiCommand = midiCommand + displayColor + " ";
          });
          send("midi", device, "/sysex", midiCommand + "F7");
        });
      }

      if (addressSplit[2]?.includes("Name")) {
        const mappingsDisplay = routingUtils.getRoutingByDisplayId(routing, fader);
        const values = args[0].value.split(";");

        mappingsDisplay.forEach((mapping) => {
          const seqMidiNote = utils.numberIntoHex(mapping.displayId * 7);
          const cueMidiNote = utils.numberIntoHex(56 + mapping.displayId * 7);
          const seq = (values[0] + "       ").substring(0, 7);
          const cue = (values[1] + "       ").substring(0, 7);

          send(
            "midi",
            mapping.device,
            "/sysex",
            "f0 00 00 66 " + getMcDeviceId(mapping.device) + " 12 " + seqMidiNote + " " + utils.stringToAsciiHex(seq) + "f7"
          );
          send( 
            "midi",
            mapping.device,
            "/sysex",
            "f0 00 00 66 " + getMcDeviceId(mapping.device) + " 12 " + cueMidiNote + " " + utils.stringToAsciiHex(cue) + "f7"
          );
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
