# BFDAC System Design Specification

**Revision:** 1.0 — intended system architecture

**Audience:** FPGA, analog, PCB, firmware and verification engineers.

**Status:** system design under review; implementation qualification is ongoing.
**PCB layout has not started.** Physical arrangements and routing rules in this
document describe the intended design.

## 1. Product purpose

BFDAC is a high-performance stereo digital-to-analog converter for music
reproduction. It accepts decoded PCM audio from an application processor,
performs interpolation and conversion processing in an FPGA, and produces
balanced line-level analog outputs using discrete current-steering converters.

The objective is a low-noise, highly linear DAC whose behavior remains consistent
from large signals down to quiet passages and digital silence. The recorded
performance ambition is to exceed the referenced dCS Vivaldi APEX noise benchmark
while preserving the distortion and low-level performance expected of a high-end
DAC. That ambition is expressed below as electrical acceptance criteria; it is
not a claim of measured product superiority.

The design is built around five connected ideas:

1. **The DAC establishes the audio timebase.** Quiet oscillators on the converter
   carrier provide the timing reference. The FPGA sets the serial-audio timing
   used by the application processor and synchronizes conversion to that reference.
2. **Digital processing prepares a controlled stream of conversion commands.**
   Interpolation, noise shaping, element selection and predistortion serve
   different purposes and operate as a coordinated chain.
3. **The analog converter delivers repeatable current contributions.** Matched
   cells, external reclocking, cascodes, replica feedforward and stable references
   control the electrical conditions under which each contribution is produced.
4. **The power and physical architecture support the signal architecture.**
   The SoM has its own switching supply. The analog path uses shared linear
   pre-regulation followed by regulation at the channel loads, with dedicated
   clock and cell-drive supply domains.
5. **Calibration and measurement are part of the system.** The board must be
   observable during bring-up, and its calibration must describe the actual
   assembled analog plant and its temperature dependence.

This document explains that intended system. Component-level implementation
evidence, discrepancies and corrective actions are maintained in the separate
[Implementation Review and Gap Analysis](IMPLEMENTATION_REVIEW.md). Register
encodings and coefficient packing are specified in
[the control/coefficient protocol](coef_format_v2.md).

### 1.1 Product capabilities

| Capability | Design definition |
|---|---|
| Audio channels | Stereo, with separate left and right conversion/I/V paths |
| Native PCM sample rates | 44.1, 48, 88.2, 96, 176.4, 192, 352.8 and 384 kHz |
| AP-to-FPGA audio interface | I²S, two 32-bit slots per stereo frame; the current word-format contract carries 24 useful bits |
| Audio-clock ownership | FPGA is I²S master; the AP transmits samples as an I²S slave |
| Conversion element count | 64 current cells per channel, 128 total |
| Converter update rates | 5.6448 MHz or 6.144 MHz, according to clock family |
| Primary analog output ranges | 2, 4 and 6 Vrms balanced full scale, selected digitally |
| Outputs | Left and right balanced XLR line outputs |
| Filters | Named interpolation filters, direct selection and an ordered user-selected toggle list |
| Low-latency use | A reserved video-mode filter, with a separate end-to-end latency qualification |
| Calibration | Per-board, per-channel correction, with AP-managed temperature compensation |
| Bring-up | Operator-paced cell, DC/level and frequency tests, plus rail and signal probing |

The sample-rate list is explicit: a maximum of 384 kHz does not mean arbitrary
rates below that value are accepted. Other word formats require an explicit
interface definition. The external source connections and codecs are determined
by the AP subsystem; the FPGA receives PCM rather than compressed music files.

### 1.2 Performance requirements

The reference output is **6 Vrms balanced**, with noise assessed over
**20 Hz–20 kHz, unweighted**, at the applicable calibration temperature.
The project uses `dB0` for measurements referenced to its full-scale output.

| ID | Mandatory requirement |
|---|---|
| N1 | At least 120 dB0 noise rejection, equivalent to no more than 6.0 µVrms at the 6 Vrms reference |
| D1 | HD2–HD8 at or below −115 dBc at −1 dBFS for in-band fundamentals |
| D2 | No spur above −120 dB0, including idle, element-selection, clock and supply-related products |
| D3 | Equal-amplitude 19/20 kHz intermodulation products at or below −115 dBc |
| L1 | Noise floor changes by no more than 1 dB between −60 dBFS and digital silence, without level-dependent spurs |

Stretch objectives are **128 dB0 noise rejection** and **HD2/HD3 at or below
−125 dBc**. Distortion margin and low-level behavior take priority over the last
increment of noise performance, provided the mandatory noise gate is met.

Qualification must define the output reference plane, load, cable capacitance,
temperature and supply corners, acquisition bandwidth and treatment of harmonics
outside the audio band. The I/V design includes a 600-ohm load case; its precise
balanced-load fixture and output-level calibration belong in the test plan.
Filter response, latency, channel matching and crosstalk also require acceptance
limits. The architecture is intended to support these measurements; their
results belong in the qualification record.

## 2. Complete system architecture

### 2.1 The physical assemblies and their roles

The product has an application/power base assembly and a converter carrier.
The Alinx ACVU13P SoM mounts to the carrier and provides the FPGA, DDR4,
configuration infrastructure and local digital regulation.

```text
  External music sources and user controls
                     |
                     v
  +---------------------------------------------------------------+
  | APPLICATION / POWER BASE ASSEMBLY                              |
  |                                                               |
  |  Application processor       Dedicated SoM 12 V switching PSU  |
  |  - source decoding/buffers    Analog linear pre-regulators     |
  |  - playback and filter UI     AP-domain supply                  |
  |  - calibration policy                                         |
  +---------+----------------------------+------------------------+
            | isolated audio/control     | separate power entries
            | through carrier barrier    | and their returns
            v                            v
  +---------------------------------------------------------------+
  | CONVERTER CARRIER                                             |
  |                                                               |
  |  Alinx SoM             Clock/reference system                  |
  |  +----------------+    - 44.1k / 48k family oscillators         |
  |  | XCVU13P FPGA   |    - clock fanout and FPGA clock copy       |
  |  | DDR4          |    - precision analog references/servos     |
  |  | NOR/config    |                                            |
  |  +-------+--------+    Carrier coefficient flash               |
  |          |                                                    |
  |          +--> L translators/reclock/cells --> L I/V --> mute --+--> L XLR
  |          |                                                    |
  |          +--> R translators/reclock/cells --> R I/V --> mute --+--> R XLR
  |                                                               |
  |  Channel regulators, power-good interlock, telemetry,          |
  |  temperature sensors, buttons, LEDs and test points            |
  +---------------------------------------------------------------+
```

The diagram shows functional partitioning. The final division of the base
assembly into circuit boards, its connector mechanics and its enclosure
implementation remain mechanical/electrical design work.

The carrier is intended to place accessible conversion circuitry and test
points on its upper face, with the SoM and board-to-board interfaces on its
lower face. This arrangement allows measurements without repeatedly turning
the board over and supports a thermal path from the SoM to the enclosure.
Section 8 develops the planned arrangement; it is not an existing PCB layout.

### 2.2 Subsystem responsibilities

| Subsystem | What it does for the DAC |
|---|---|
| Application processor | Understands the music stream, buffers/decodes it, reports PCM rate/format, implements user policy, requests filters and volume, reads telemetry and prepares calibration values |
| XCVU13P FPGA | Converts the reported stream into synchronized cell commands; owns rate configuration, I²S timing, digital processing, coefficient transport, diagnostic patterns and playback control sequencing |
| SoM infrastructure | Supplies FPGA configuration, DDR4, local digital power and a stable control-clock source |
| Carrier clock system | Establishes the two audio clock families and distributes the physical sampling clock to the reclock devices |
| Left/right converters | Transform element-selection patterns into complementary analog current contributions |
| References and bias circuits | Establish current, common-mode and device-compliance conditions for the converters |
| Left/right I/V stages | Convert the complementary currents into balanced line-output voltages |
| Output mute system | Disconnects the line outputs from the I/V stages and grounds the connector-side signal contacts while muted |
| Power system | Delivers the SoM supply and analog pre-regulated rails, then regulates/filter them at their loads |
| Telemetry and calibration system | Measures temperatures/supply conditions and maintains the correction data used by the digital processing |
| External measurement fixture | Measures analog performance and supports board identification, calibration and qualification |

### 2.3 A playback example

For a 192 kHz PCM stream, the AP reports the rate and supplies the requested
filter identity. The FPGA selects the 49.152 MHz carrier clock family and
configures a total interpolation factor of 32. It supplies a 12.288 MHz I²S
bit clock and 192 kHz frame clock to the AP.

The AP transmits the stereo samples on those clocks. The FPGA interpolates
them to 6.144 MHz, applies the selected gain and conversion processing, and
chooses a physical-cell mask for each channel. The masks are encoded into
return-to-zero commands and launched to the carrier.

The external flip-flops capture those commands using the dedicated clock
fanout. Their complementary outputs control the current-steering cells.
The resulting currents pass through the cascode network into the I/V
stages. When startup, calibration and playback conditions are satisfied,
the mute relays connect the resulting balanced voltages to the XLR outputs.

This is one continuous conversion system: the serial-audio clocks, FPGA
processing cadence and physical reclock timing all derive from the carrier's
audio timebase.

## 3. Application processor and control architecture

### 3.1 Stream knowledge and buffering

The AP handles source-facing work: decoding, source selection and buffering.
It knows the decoded stream's sample rate and word format and reports them to
the FPGA. It must deliver samples at the timing requested by the FPGA.

Transport arrival timing and conversion timing have different roles. Network,
storage or other source traffic may arrive in bursts. The AP's buffer absorbs
that variation; packet-arrival or software-scheduling jitter must not become
the conversion clock. Source flow control and buffering must sustain the
DAC-governed drain rate.

An AP underrun or source stop must be reported explicitly. Locally generated
I²S clocks will continue to exist even when the AP has no valid samples.
Constant-zero DATA can be legitimate silence, so the FPGA cannot infer source
health merely by watching whether DATA changes.

### 3.2 Ownership contract

The AP requests an **audio operating mode**, not a collection of unrelated
clock settings. The FPGA translates a supported rate into a coherent choice
of oscillator family, I²S dividers and interpolation ratio.

| Decision | Owner |
|---|---|
| Which music source is playing and its native PCM rate/format | AP |
| User-selected filter and volume target | AP |
| Compatibility of the requested stream/filter with the hardware mode | FPGA validation |
| Physical oscillator selection and I²S clock generation | FPGA |
| Interpolation configuration and processing cadence | FPGA |
| Internal FPGA clock multiplier/divider design | FPGA implementation, constrained by timing/throughput |
| Reporting ready, busy, applied configuration and hardware-detected errors | FPGA |
| Temperature interpolation and preparation of calibration coefficients | AP |
| Maintaining safe clock/rate transitions and controlling output-unmute eligibility | FPGA sequencing plus hardware interlock |

The AP must wait for the applied configuration and satisfy the stream/filter
readiness contract before playback is allowed. Unsupported requests must fail
explicitly rather than being silently mapped to another rate.

### 3.3 Communications

Three interfaces connect the AP subsystem to the carrier:

- **I²S:** FPGA-to-AP BCLK/LRCLK and AP-to-FPGA audio DATA.
- **Register SPI:** AP-originated configuration and status transactions,
  with FPGA MISO/IRQ responses.
- **I²C/PMBus:** AP access to carrier temperature sensors and rail-monitor
  devices through the isolation interface.

The AP-side power/return domain is `VAP_IO`/`GND_AP`. Digital isolators carry
the signals across to the carrier/SoM domain. The design must preserve that
boundary across every connection, including status, reset and debug access.

The intended AP device must support I²S slave transmission at the agreed rates,
the register-control protocol, sufficient buffering, and the required software
functions. Its exact processor, operating software and external source/UI
connections are not yet selected.

### 3.4 Filter and volume policy

Filters are presented to users by name. The AP maintains the name-to-ID
association and an ordered toggle list of up to 32 entries. A user can select
any filter directly, as well as advance through the list. The first list entry
provides the user's default selection at startup.

The FPGA receives numeric IDs, loads the requested compatible coefficients
into an inactive bank, and activates a complete set at a safe processing
boundary. The design goal is uninterrupted filter selection without using a
partially loaded or mixed coefficient set. Transition behavior must be defined
and verified for the selected filter combinations.

The AP owns the volume slew policy. At startup, volume is zero; after safe
unmute it can be raised to the requested level. The primary output-range
selection is 2/4/6 Vrms at full scale. The control map also contains 0.6/0.2 Vrms
gain caps. These are digital scaling choices around one fixed analog I/V gain.

Keeping the analog gain fixed maintains one analog feedback configuration.
Reducing the digital level also reduces signal-to-fixed-analog-noise ratio;
the principal noise acceptance reference is therefore the 6 Vrms range.

## 4. FPGA conversion architecture

### 4.1 Processing flow and the purpose of each block

```text
  PCM stereo from the AP, timed by FPGA-generated I²S clocks
                              |
                    Capture / frame validation
                              |
                Rate-appropriate polyphase FIR
                              |
                 Three halfband x2 stages (x8)
                              |
                  Volume / level / boot envelope
                              |
                    Elastic output-rate pacer
                              |
               Dither + error-feedback noise shaper
                        ^                  |
                        |                  | aggregate conversion code
              Predistortion correction    v
                                     Dynamic element matching
                                              |
                                    64-bit selection/channel
                                              |
                                  RTZ encoding / IOB launch
                                              |
                                  External carrier reclocking
```

**Serial capture** converts timed serial slots into stereo sample words.
It must account for the outgoing-clock and returning-DATA delays through
the isolation interface and AP. It also carries source-readiness and
framing/cadence information into the playback control system.

**Interpolation** produces a higher-rate representation of the input
waveform while suppressing interpolation images. The long polyphase FIR
provides the selected main filter response. Three halfband stages provide
the remaining factor of eight efficiently.

**Gain processing** applies the host's volume, the output-range cap and
the startup envelope. Internal arithmetic needs sufficient headroom and a
documented scaling convention so that a nominal full-scale PCM signal
corresponds to the intended analog level without hidden overflow or attenuation.

**The pacer** reconciles burst-oriented filter computation with evenly
spaced converter updates. Its drain rate is tied to the audio master clock.
Buffering absorbs scheduling bursts; it does not excuse a sustained mismatch
between generated samples and consumed samples. Overflow/underflow must
be observable and inhibit unsafe playback.

**Dither and noise shaping** convert the high-resolution processed signal
to the limited aggregate code range of the cell array while shaping
quantization error outside the audio band. The selected noise-shaper
architecture is a third-order error-feedback design with an IIR noise-transfer
function. It receives full-range TPDF formed from independent 42-bit uniform
streams, carried in a signed 43-bit container. L/R generators use different
seeds. Low-level and idle behavior remain explicit measured-performance
requirements.

**Dynamic element matching (DEM)** translates the aggregate code into a
choice of physical cells. A second-order vector mismatch shaper spreads
the effect of unequal cell currents rather than assigning one fixed
thermometer pattern to each code. The reference algorithm ranks the cells
using their accumulated selection errors and chooses the required number.

**Predistortion (DPD)** models repeatable static and transition-dependent
errors of the analog conversion path. It corrects the noise-shaper feedback
using identified LUT/kernel data. Its purpose differs from DEM: DEM addresses
physical-element mismatch, while DPD addresses the modeled aggregate
conversion error. Neither removes the need for linear analog circuitry.
The RTL draft uses a faster DSP MMCM ratio to budget 49.23 DSP clocks per
converter update and flags a missing correction at the next Stage-A read.
That deadline margin is subject to the 49/50-cycle DPD regression and routed
timing; it is not yet sign-off evidence.

**RTZ and external reclocking** define the temporal shape of a selected
cell's contribution and place the final capture edge at the analog converter.
Correct selection masks, equal pulse width and valid external setup/hold
are all parts of the conversion contract.

### 4.2 Rates and capacity

The FPGA maintains a fixed converter update rate within each audio family.
The total interpolation factor changes with native PCM rate:

| Native PCM / LRCLK | Selected carrier MCLK | Total interpolation | I²S BCLK, 64 clocks/frame | Converter update rate |
|---|---:|---:|---:|---:|
| 44.1 kHz | 45.1584 MHz | ×128 | 2.8224 MHz | 5.6448 MHz |
| 48 kHz | 49.152 MHz | ×128 | 3.072 MHz | 6.144 MHz |
| 88.2 kHz | 45.1584 MHz | ×64 | 5.6448 MHz | 5.6448 MHz |
| 96 kHz | 49.152 MHz | ×64 | 6.144 MHz | 6.144 MHz |
| 176.4 kHz | 45.1584 MHz | ×32 | 11.2896 MHz | 5.6448 MHz |
| 192 kHz | 49.152 MHz | ×32 | 12.288 MHz | 6.144 MHz |
| 352.8 kHz | 45.1584 MHz | ×16 | 22.5792 MHz | 5.6448 MHz |
| 384 kHz | 49.152 MHz | ×16 | 24.576 MHz | 6.144 MHz |

The reference realization uses 16, 8, 4 or 2 active polyphase FIR phases,
followed by the ×8 halfband chain. The FIR output then remains at
705.6/768 kHz for all supported native rates. Those internal rates do not
extend the native input limit beyond 384 kHz.

The FPGA compute-clock configuration can remain constant within a family.
The current RTL draft uses MMCM `CLKOUT0_DIVIDE_F=3.25` with a VCO multiplier
of 20: approximately 277.898 MHz for the 44.1 kHz family and 302.474 MHz
for the 48 kHz family. That gives about 49.23 DSP clocks per converter update,
chosen to provide margin for the error-feedback predistortion deadline.
Achievable clock rate, setup/hold and routed timing at production resources
remain unqualified; the selected MMCM ratio is not proof of timing closure.

Filter capacity and tap count must be specified per native rate.
The reference storage organization reserves sixteen phase slots per MAC;
the active FIR tap count is:

```text
active phases = 16 / native-rate multiplier
active taps   = active phases × NUM_MACS × TAPS_PER_PHASE
```

For example, `NUM_MACS=256`, `TAPS_PER_PHASE=256` provides 1,048,576 active
taps at base rate and proportionately fewer active taps at higher rates.
Unused phase slots remain reserved in the reference coefficient-bank format.
Rate-specific coefficients need the correct response and normalization;
discarding phases from an arbitrary base-rate filter does not establish
that response.

The XCVU13P was selected for long filters, dual coefficient banks and
processing/routing headroom. A 1280-by-256 configuration corresponds to
5,242,880 active base-rate taps. Larger mathematical filter targets, including
the discussed 10M target, require a separately qualified resource/dataflow
configuration. The product's supported filter library and tap claims follow
that qualification rather than a parameter setting alone.

### 4.3 Memory and filter management

Configuration flash, coefficient flash, DDR4 and active FPGA coefficient
memory have different roles:

| Storage | Role |
|---|---|
| SoM configuration flash | Persistent FPGA configuration infrastructure |
| Carrier coefficient NOR, with SoM coefficient-flash fallback | Persistent filter-image storage and provisioning |
| SoM DDR4 | Staging/storage for the available filter images and their directory |
| Dual-bank FPGA coefficient storage | Active filter plus inactive bank receiving the next filter |
| Dual-bank calibration store | Active and prepared per-channel correction data |

The FPGA autonomously stages persistent coefficient records into DDR4 after
configuration and memory readiness. The AP then requests its default
compatible filter. A staged image and an active, valid FIR bank are separate
states.

Coefficient images carry enough metadata to identify the filter, its rate
compatibility, layout and integrity. Invalid images must not replace a valid
active filter. The image-building, transport and loader definitions must agree
on byte order, CRC coverage, dimensions, padding and rate encoding.

The inactive bank is filled while the current bank is in use. FIR-bank
activation waits for the native input frame's final active interpolation phase;
the bank-select tree then settles before the next FIR sweep. This prevents a
single native frame from using coefficients from two filter banks. The same
consistency requirement applies to serial DPD coefficient reads during
calibration updates.

### 4.4 Numeric and temporal contracts

The reference realization uses 24-bit audio samples, signed 18-bit FIR
coefficients, wider FIR/halfbands/gain arithmetic, and a noise-shaper input
expressed in cell/code units. DPD has its own signed coefficient and scaling
format. These widths are implementation choices that require a unified
fixed-point ledger covering normalization, headroom, rounding, clipping and
feedback signs.

Normal aggregate codes use a seven-bit container with a 0–63 operating
range; the physical array contains 64 cells. Digital silence must map to the
calibrated analog midpoint, not to all DATA pins low. The recorded analog
offset-injection operating point uses a mean code of 32.5; the numeric
implementation and calibration must reproduce the agreed operating point
consistently.

For each channel, a selected cell receives a six-clock active interval
within an eight-MCLK conversion period. The intended duty is 75%.
At 49.152 MHz the period is about 162.76 ns and the active interval
about 122.07 ns. At 45.1584 MHz they are about 177.15 ns and 132.87 ns.

The FPGA pipeline must preserve stereo alignment, cell numbering, packet
width and sample conservation. A faster average computation rate does not
prove that every feedback result or output word meets its individual deadline.

### 4.5 Latency and the video filter

Long linear-phase interpolation filters intentionally exchange latency for
the chosen response. At a 768 kHz FIR output rate, a 1,048,576-tap linear-phase
filter has approximately 0.683 s of group delay; 5,242,880 taps correspond
to approximately 3.413 s, before other buffering.

The product therefore has a separately selected video mode using one
reserved low-latency filter. Its recorded budget is at most 20 ms
end-to-end. The filter builder and system test must establish that budget;
choosing a minimum-phase label or reading metadata is not sufficient.
The user selects the mode manually; it is not inferred from the audio link.

## 5. Clock architecture

### 5.1 The conversion timebase

```text
  Crystek 45.1584 MHz XO ----\
                             >-- selected XOCLK --+--> L fanout tree --> 64 L FF clocks
  Crystek 49.152 MHz XO ----/                     |
           ^                                     +--> R fanout tree --> 64 R FF clocks
           |                                     |
     FPGA family selection                       +--> buffered FPGA clock copy

  FPGA clock copy --> MMCM --+--> DSP clock --> processing / DATA capture
                            |
                            +--> cell clock --+--> RTZ output launch
                                              |
                                              +--> I²S divider --> isolator --> AP
                                                                                |
  FPGA DATA capture <------------------------------------------- isolator <------+
```

The oscillators generate the physical master clock. The FPGA chooses
which family is active and derives the digital processing and serial-audio
timing from it. There is no separate MCLK export to the AP in the agreed
interface; the AP receives BCLK/LRCLK and acts as a slave transmitter.

The physical clock delivered to each external reclock FF follows the
oscillator/fanout path. This keeps the final conversion capture edge near
the analog cells and avoids making a software-controlled AP clock the
conversion reference.

### 5.2 Reclocking and timing closure

The FPGA launches one data bit per cell. Translators deliver that bit to
the external FF's D input. The FF produces both Q and its complement for
the analog steering network.

The DATA launch phase must provide setup and hold margin relative to the
external FF clock. That budget includes SoM internal routing, connectors,
FPGA output delay, translation delay, carrier traces, clock-tree skew and
PVT variation. External reclocking is effective only when DATA is captured
correctly; it does not remove the reclock device's own timing uncertainty.

The I²S return path has a different timing problem. A clock travels from the
FPGA through isolation to the AP, the AP launches DATA, and DATA returns
through isolation. Capture timing must accommodate this complete round trip.
The reference RTL provides adjustable delayed capture; production settings
must be qualified for both families and the fastest supported native rate.

### 5.3 Clock domains and transitions

The architecture contains a stable control domain, an audio-locked DSP
domain, a cell-launch domain and the memory-controller user domain.
Transfers between them must preserve multi-bit coherence as well as event
delivery. Reset release, stopped clocks and configuration epochs are part
of each transfer contract.

An oscillator or native-rate change is a controlled transition:
mute first, quiesce old-format traffic, reset/reconfigure the affected audio
path, establish the new clocks, restore compatible filter/calibration state,
and then permit playback. A nominally valid oscillator frequency alone
does not establish readiness of the complete conversion path.

## 6. Discrete converter and analog output

### 6.1 Current cells and steering

Each channel contains 64 nominally matched current cells. The selected
component families are THAT300 matched NPN arrays for current-source
transistors and DMMT5551 dual NPN devices for the steering pairs.
The tail network establishes each cell's nominal current.

A complementary FF output pair selects the branch to which the cell
contributes. The base-drive network translates the FF's 3.3 V logic swing
into the analog steering levels, nominally approximately 1.1/1.7 V.
The reference network uses 1.35k series and 301-ohm shunt elements,
with local base stoppers.

The current source remains an analog circuit when its data bit is low.
Low DATA steers it to the other branch; it is not a power-disable command.
This distinction is essential to interpreting digital silence, RTZ and
startup/fault behavior.

### 6.2 Cascode, replica and padding functions

```text
                         One channel

    64 reclocked complementary steering signals
                         |
             +-----------+-----------+
             |                       |
        PLUS current bus        MINUS current bus
             |                       |
       cascode stack             cascode stack
             |                       |
           COL_P                   COL_M
             |                       |
           I/V P                   I/V M

    FF activity sums --> replica/feedforward --> cascode-bias control
    Reference/servo network ------------------> bias/compliance setpoints
    Padding and bus networks -----------------> operating-point conditioning
```

The cascode stacks use Si1555DL devices to reduce the influence of downstream
voltage variation on the steering cells and establish controlled compliance
conditions between the current buses and I/V summing nodes.

The replica/feedforward network observes the activity of the actual FF
outputs through summing resistors. Its 2SA1036K-based current-control
circuitry influences cascode bias to compensate repeatable activity-related
disturbances. This makes the FF output loading part of the analog plant:
adding capacitance or load to Q/Q-complement can change the compensation.

Padding-current and bus networks keep device operating conditions controlled
across the code range. The design uses nominal 50 mA padding paths and
47 nF bus capacitors. Their current, noise, heat and stability consequences
are part of the complete analog design rather than isolated decoupling choices.

DEM, replica feedforward and DPD address different error mechanisms.
The system needs all three to be consistent with the same physical
converter, timing and calibration model.

### 6.3 I/V conversion

Each channel has two complementary I/V branches. An OPA1612 front amplifier
and a BUF634A output buffer operate inside one feedback loop per branch.
The nominal feedback network is 270 ohms in parallel with approximately
1.3 nF, with 12 nF at each summing node.

The summing nodes are held around a **4 V virtual-ground reference**.
Offset-injection current from the approximately +15 V `V_ROFF` rail
establishes the required DC balance. The reference realization uses four
536-ohm resistors in parallel on P and four 464-ohm resistors in parallel
on M. These networks dissipate meaningful power and must be thermally
separated from sensitive matching/reference structures.

The I/V loops produce the balanced output voltage directly. There is no
additional line voltage-gain stage or separate historical reconstruction-filter
stage in the selected signal chain. Bandwidth, image rejection, stability,
output drive and overload behavior must therefore be assessed for the complete
converter/I/V/output network.

Nominal full scale is 6 Vrms differential, with each leg carrying an
opposite-polarity contribution. The final calibration and acceptance
measurements must use a specified output reference plane and load.

### 6.4 References and bias generation

One REF7050 precision source and its filtered/buffered `REF5F` node establish
a common reference basis for both channels. Channel-local circuits derive
VREF, V_VG, VCM, VFR, VB1/VE1 and cascode/padding setpoints.

| Reference/bias function | Purpose |
|---|---|
| VREF / tail-base network | Establish the cell-current reference |
| V_VG | Set the I/V summing-node common-mode voltage |
| VCM | Establish the steering-drive network reference |
| VFR and cascode controls | Set bus/cascode compliance conditions |
| VB1 / VE1 | Set the replica/feedforward operating point |
| PADB control | Establish the padding-current condition |
| REF5F | Common precision basis from which the setpoints are derived |

These nodes have different current-source/sink and dynamic requirements.
A precise divider value alone is not a sufficient reference circuit.
Buffer drive capability, loop stability, startup, capacitor behavior,
thermal gradients and loading must support the function of each node.

The shared precision source helps establish a common basis for left/right
tracking. Actual channel matching still depends on component ratios,
temperature, layout and calibration.

### 6.5 Output connection and mute

The I/V outputs connect through 10-ohm build-out resistors and non-latching
mute relays to the balanced XLR connectors. The selected families are
Omron G6K-2F-Y DC3 relays and Neutrik NC3MD-H-B XLR connectors.

With the relays de-energized, the XLR signal contacts are grounded and
disconnected from the I/V output. The coils are continuously energized
while unmuted, using their dedicated rail and low-side drivers.
There is no relay-coil economizer PWM in this design.

The unpowered contact state supports safe startup and shutdown. The time
needed to reach that state is a physical relay-release interval and must
be included in the power-fail and transient budget.

## 7. Power, grounding and thermal architecture

### 7.1 Supply partition

```text
  Dedicated switching supply, filtered 12 V
                      |
             left-side power entry
                      |
                 Alinx SoM
             FPGA / DDR / local POLs
                      |
                exported V18 --> carrier digital interface

  Linear analog supply front end
  transformer / rectification / reservoir / pre-regulation
                      |
          shared P16A / N16A / V8P3 / V4P3
               +------+------+
               |             |
          top entry      bottom entry
               |             |
        L analog POLs   R analog POLs
               |             |
        L converter/IV  R converter/IV

  Shared pre-regulator feeds also supply:
       dedicated V33CLK regulator --> both clock trees
       dedicated V33FF regulator  --> translator/FF islands
       V33D and V33RLY regulators --> telemetry and relay functions
```

The SoM's 12 V supply is a dedicated switching supply with provision for
up to 15 A at the interface. That figure sizes supply/connector/current-path
capacity; it is not a claim of continuous 180 W FPGA consumption.
The noisy power and digital interfaces are intended to remain on the left
side of the carrier, away from the sensitive analog conversion area.

The analog supply architecture uses **shared upstream pre-regulators and
separate final analog regulators per channel**. Shared upstream rails
provide common supply infrastructure; separate local regulators reduce
shared load-modulation paths and place regulation close to the analog loads.

Clock regulation is deliberately different: one dedicated final regulator
supplies the clock network spanning both channels. The clock network remains
separate from the cell-drive and general digital supply loads.

### 7.2 Supply functions

| Rail | Nominal value | Scope and purpose |
|---|---:|---|
| V12SOM | +12 V | Dedicated SoM power entry; also supplies the new buffered bring-up LED loads |
| V18 | +1.8 V | SoM-exported interface supply, FPGA bank reference, translator A sides and FPGA-side control interfaces |
| P16A / N16A | +16.2 / −16.2 V | Shared analog pre-regulator inputs |
| V8P3 / V4P3 | +8.3 / +4.3 V | Shared pre-regulator inputs for lower-voltage functions |
| V_ROFF_L/R | Approximately +15 V | Separate channel offset-injection supplies |
| P15A_L/R / N15A_L/R | Approximately ±15 V | Separate channel analog-amplifier supplies |
| VEE15_L/R | Approximately −15 V | Separate converter/padding sink-return supplies |
| VE1_L/R | Approximately +7.2 V | Channel replica/emitter operating-point supplies |
| P5A_L/R | Approximately +3.3 V | Channel VCM-related supply; the net name is historical |
| V33CLK | Approximately +3.3 V | One clock-only regulator for both channel trees and oscillators |
| V33FF | +3.3 V | Shared translator/FF supply, with local filtering islands |
| V33D | +3.3 V | Board telemetry and general digital loads |
| V33RLY | +3.3 V | Enabled relay-coil supply |
| VAP_IO | AP-domain logic supply | Powers the AP side of the carrier isolation interface |

LT3045 and LT3094 devices provide the positive and negative analog
regulation functions. ADP7158 is used for V33FF; TPS7A2033 devices serve
V33D/V33RLY. Headroom is budgeted by regulator and load, including upstream
tolerance and distribution loss.

Power budgets must include the converter's standing currents, amplifiers,
clock fanouts, switching activity, indicators, startup/inrush and thermal
derating. Connector selection must use those budgets, including return
contacts, rather than assuming all pre-regulator feeds are low-current.

### 7.3 Ground and isolation domains

```text
  AP domain                                  Carrier / SoM domain
  VAP_IO + GND_AP                             V18 + carrier GND
       |                                             |
       +---- SPI / I²S / reset / I²C isolators ------+

  Dedicated SoM supply return ----+
                                  +--> engineered carrier return structure
  Analog supply returns ----------+

  XLR shield / metal enclosure ----> defined chassis-bond arrangement
```

Separate SoM and analog power sources provide supply partitioning. The
FPGA-to-converter interface still uses the carrier ground reference.
The AP isolation boundary is a separate architectural function and must
be maintained across power returns, signal interfaces and service connections.

The layout must keep high-current/digital return paths from producing
uncontrolled voltage across precision reference and signal returns.
The chassis, XLR shield, signal ground and safety-earth relationships must
be defined in the complete product grounding plan.

### 7.4 Thermal design

Temperature affects cell matching, resistor ratios, references and the
identified correction model. Thermal behavior is therefore part of the
conversion architecture.

The intended assembly provides a dedicated heat-removal path for the SoM,
uses the enclosure to manage sustained dissipation, and keeps concentrated
I/V offset/padding heat away from precision matching structures.
Local temperature sensors provide the AP with the information needed for
calibration selection and monitoring.

Warm-up readiness should be based on qualified settling and thermal behavior.
A historical approximately 120-second soak value is a working placeholder,
not a substitute for measured startup requirements. The factory fixture
should reproduce the intended thermal mounting arrangement sufficiently
well for its calibration to remain applicable in the enclosure.

## 8. Planned board arrangement and interconnects

**PCB layout has not started.** The following is the intended floorplan
and the constraints that should guide placement and routing.

### 8.1 Physical arrangement

| Region / face | Intended contents and reason |
|---|---|
| Carrier lower face | SoM, coefficient flash and base-assembly connectors; supports the SoM's downward thermal/mechanical connection |
| Carrier upper face | Reclocking, current cells, analog circuitry, clock distribution, local regulation and probe access |
| Left digital region | SoM power entry and AP/control interconnects, physically separated from low-level analog circuitry |
| Analog/clock region | Short oscillator-to-fanout paths and matched clock/data distribution near the cells they serve |
| Top-edge connector group | Left-channel pre-regulator distribution and the clock-side supply feed |
| Bottom-edge connector group | Right-channel pre-regulator distribution and cell-drive/general-digital supply feeds |
| Output edge | I/V-to-relay-to-XLR paths, with mechanical connector access and relay temperature limits considered |

“Top/bottom edge” in the connector plan denotes plan-view board edges;
“upper/lower face” denotes the two sides of the PCB. These must remain
distinct in mechanical drawings.

The working board-to-board separation is approximately 30 mm. Separate
power and signal connector bodies are acceptable. The SoM, its heatsink
and the base assembly must have compatible clearances; mounting hardware
must carry mechanical loads rather than relying on connector contacts.
The 30 mm working target concerns the carrier-to-base connection; the
SoM-to-carrier mating interface has its own mechanical dimensions.

Both analog entry groups carry the shared upstream rails. Local placement
and return routing must implement the intended channel distribution;
duplicated connectors on the same nets do not create independent supplies.

### 8.2 Layout requirements

Placement and routing shall preserve:

- The end-to-end data/clock timing budget, including SoM internal routing,
  connector delay, translator delay, carrier routing and retimer timing.
- Matched cell geometry, thermal environment and parasitic loading.
- The intended Q/Q-complement drive and replica-feedforward loading.
- Compact summing nodes, controlled bias/reference returns and suitable
  regulator/reference Kelvin connections.
- Clock-source isolation from noisy digital/current loops and short XOCLK
  routing before the fanout.
- Separation of concentrated heat from matching-critical components.
- Accessible test points with short probe returns and controlled stub loading.
- Continuous, intentional signal-return paths through vias and connectors.

The layer stackup, impedance rules, via strategy, matching limits and
capacitance budgets must be established before routing. The carrier
assembly policy favors 0603 passives, with documented 0402 exceptions where
the local electrical/routing requirements justify them.

### 8.3 Mechanical and assembly deliverables

The hardware handoff must include an approved floorplan, connector mating
drawings, thermal mounting details, stackup, electrical constraints and
assembly variants. Exact board-to-board connector part numbers and
footprints remain selection work; provisional family names are not
manufacturing specifications.

The first article may populate one analog channel while retaining shared
infrastructure. The population matrix must explicitly preserve shared
references, clocks, monitoring and their supply dependencies. It must not
simply remove every component drawn on the other channel's sheets.

The repository's SoM connector seed is a mechanical reference for later
work. It is not a completed placement or routed converter board.

## 9. System operating sequences

### 9.1 Startup to playback

```text
  Power applied
       |
       v
  Hardware output mute remains de-energized
       |
       v
  SoM configures FPGA; control, audio clocks and supplies establish
       |
       +--> FPGA stages coefficient images into DDR4
       +--> AP initializes policy, monitoring and calibration state
       |
       v
  AP reports stream rate/format and chooses a compatible filter
       |
       v
  FPGA applies clocks/processing; loads and validates the active filter
       |
       v
  Required calibration, analog settling and source readiness established
       |
       v
  Unmute permitted at zero volume; AP slews volume to the requested level
```

Configuration complete, rail power-good, clock readiness, valid coefficient
state, calibration readiness and AP source readiness are different conditions.
The playback state must combine the relevant conditions rather than treating
any one of them as universal readiness.

The hardware mute gate combines FPGA configuration DONE, rail power-good
and the FPGA relay request. This gives an independent hardware qualification
of the output connection. Software and FPGA sequencing remain responsible
for requesting unmute only when the complete playback state is valid.

### 9.2 Native-rate change

1. The AP reports the new rate/format and quiesces the old stream.
2. The FPGA validates the request and blocks competing configuration changes.
3. Outputs are muted, with the physical release interval respected.
4. The FPGA selects the appropriate oscillator family and resets/reconfigures
   the affected processing and serial interface.
5. Compatible filter and calibration state are restored and validated.
6. The FPGA reports the applied configuration; the AP supplies the matching
   stream and declares readiness.
7. Playback resumes only through the explicit unmute/volume sequence.

A change within the same oscillator family still changes I²S timing and
interpolation. It is a complete stream-mode transition even if the physical
oscillator does not need to change.

### 9.3 Filter and calibration updates

Filter data is written into an inactive bank and checked before activation.
The bank manager commits a loaded filter only after the full native input
frame (all active interpolation phases) completes. The distributed bank-select
tree settles before the next input frame starts its FIR sweep.

Calibration follows the same principle. The AP prepares a complete
temperature-corrected dataset, writes the inactive calibration bank,
verifies it and requests activation. The store holds bank activation until
the DPD read engines are idle at an eligible sample boundary. Further writes
and commits are rejected while a commit is pending. A DPD operation must use
one coherent dataset from start to finish.

### 9.4 Source stop, faults and recovery

An AP source stop/underrun must remove source readiness and cause controlled
muting. Clock loss, invalid coefficient state and detected datapath faults
must inhibit playback. Rail power-good failure acts through the hardware
mute gate independently of AP software.

The protection design must account for physical release time, stored energy,
amplifier overload and intermediate converter states. Outputs should remain
muted during recovery until the required clocks, analog conditions and
processing/source state have been re-established. The system must define
which events require an explicit re-arm and which require a full reset.

### 9.5 Shutdown

For controlled shutdown, the AP slews volume down where possible, requests
mute and allows the contacts to release before power is removed. Abrupt
power loss relies on the hardware default state and the power-fail timing
budget. Shutdown qualification must include the actual downstream load and
the supply collapse sequence.

## 10. Calibration and monitoring

### 10.1 Calibration model

Calibration identifies repeatable behavior of the assembled converter,
including static code error and history-dependent transition error.
The correction model must use the same physical drive, references,
operating point and timing as the product.

The intended process is:

```text
  External measurement fixture
              |
       known stimulus records
              |
   model identification and held-out validation
              |
   per-board / per-channel calibration datasets
              |
   AP selects/interpolates for measured temperature
              |
   FPGA inactive calibration bank --> verified activation --> DPD
```

The FPGA applies the supplied correction in real time. The AP performs
temperature-related preparation and manages dataset policy/versioning.
Factory/service tooling performs identification and establishes that the
correction improves independent validation records.

Per-cell measurement is a useful diagnostic, but a physical-cell weight map
is not automatically the same object as the aggregate code LUT and Volterra
kernel used by the DPD engine. The identification procedure must define the
relationship between measurements and each correction term.

### 10.2 Temperature and rail monitoring

TMP117 sensors observe selected thermal regions such as the cell arrays,
high-dissipation precision-resistor areas and clock region. Two UCD90120A
devices provide rail telemetry and fault information through distinct
PMBus addresses.

The AP can use these readings for diagnosis, calibration selection and
operating policy. The UCD devices are telemetry components; the essential
output-mute interlock does not depend on their firmware/configuration.
The hardware `PG_ALL` network is formed from regulator power-good outputs
and a separate supervisor for the FF rail.

## 11. Bring-up and service measurement

### 11.1 Operator-paced testing

The board provides two tactile buttons and one active-test indicator:

- Button 1 selects a test by counting presses within a fixed three-second window.
- Button 2 advances one measurement condition.
- The selected condition remains indefinitely until the operator advances it.
- The test LED flashes at the selected test's rate while the test is active.
- An additional STEP after the final right-channel condition completes the test.
- A long SELECT hold cancels; completion/cancellation leaves the outputs muted.

| Selection | Measurement purpose | Sequence | Indicator |
|---|---|---|---|
| 1 | Individual cell contribution and converter/I/V interface behavior | Baseline then selected cell added, for cells 1–64, left then right | 1 Hz |
| 2 | DC operating point, polarity and level response | Offsets 0, +1, −1, +4 and −4 cell-equivalents, left then right | 2 Hz |
| 3 | Frequency response | Continuous 1–20 kHz sine in 1 kHz steps, left then right | 3 Hz |

The cell baseline uses a fixed selection of 32 other cells; the paired
measurement adds only the cell under test. The frequency stimulus uses
a conservative fixed amplitude. These are externally measured test
conditions, not an autonomous pass/fail sweep.

The interface is intended to work without a running AP or audio stream
once FPGA configuration, clocks and required supplies are available.
Status is also available through SPI when a host is connected. Automated
test control can build on the same measurement definitions later.

The selected buttons are Würth **434133025816**. The new LED circuits use
Kingbright **APT1608LSECK/J3-PRV** red 0603 devices at approximately
**500 µA nominal**. The test indicator draws LED current from the SoM
12 V domain through an FPGA-controlled transistor. Its status flashing
continues during acquisition as agreed.

### 11.2 Probe access

The carrier provides access to pre-regulated and final rails, references,
selected cell-drive/clock signals, control handshakes, summing nodes and
pre-relay analog outputs.

| Channel | Summing P / M taps | Dedicated ground pads | Pre-relay I/V P / M taps |
|---|---|---|---|
| Left | TP987 / TP988 | TP992 / TP993 | TP985 / TP986 |
| Right | TP787 / TP788 | TP792 / TP793 | TP785 / TP786 |

Summing-node taps use 1k isolation resistors. They are intended for observing
compliance and settling with a suitable low-capacitance probe. The resistor
reduces probe loading and limits the observed bandwidth; it does not eliminate
loading. These are not 50-ohm or direct-ammeter ports.

Cell contribution is inferred from the settled difference at the I/V
outputs between paired conditions. Sign, transimpedance, RTZ duty,
replica interaction and instrument loading must be accounted for when
turning that difference into an absolute current or calibration value.

### 11.3 Supply-presence indication

Small steady LEDs provide a quick visual indication for 23 supply rails,
including pre-regulator feeds. They indicate approximate presence, not
voltage accuracy or regulation limits. The rail test points and telemetry
provide the measurements.

The 1.8 V indication is transistor-sensed with LED power supplied from 12 V
to provide adequate LED headroom. Precision references, SET pins, bias
nodes and summing nodes do not receive LED loads. Indicator visibility and
actual current must be checked on the first assembly.

## 12. Interface contracts

The following contracts connect the system's components and should be
maintained explicitly as implementation details evolve.

| Boundary | Producer's responsibility | Consumer's responsibility |
|---|---|---|
| AP → FPGA stream request | Report the intended PCM rate/format and requested filter | Validate support/compatibility and apply a coherent mode |
| FPGA → AP serial timing | Supply BCLK/LRCLK derived from the selected audio timebase | Transmit correctly framed DATA and maintain buffering |
| AP → FPGA source status | Declare valid source data; report stop/underrun | Inhibit playback when readiness is absent |
| Persistent images → coefficient loader | Provide correctly packed, identified and integrity-protected data | Validate bounds/layout/rate and reject invalid images |
| Calibration tooling/AP → FPGA | Supply a complete identified dataset for the board/channel/temperature policy | Activate and apply coherent data with bounded arithmetic and latency |
| FPGA → external reclock FFs | Correct masks, bit mapping, RTZ timing and setup/hold at the pins | Capture using the distributed clock and produce the complementary analog drive |
| Converter → I/V | Deliver current within the agreed bias/compliance and dynamic envelope | Maintain summing-node conditions and convert current without instability or overload |
| Power system → loads | Meet voltage, noise, startup, current and thermal requirements | Stay within load/inrush budgets and report applicable faults |
| Hardware interlock → XLR path | Permit connection only under the defined hardware conditions | FPGA/software must also enforce complete playback readiness |
| Board → external fixture | Expose defined test conditions and accessible probe/reference points | Measure with qualified loading, timing, uncertainty and traceability |

The control protocol document owns bit-level register/frame definitions.
The BOM and schematics own the selected component realization.
The FPGA constraints and PCB constraints must jointly express the timing
and loading assumptions at their physical boundary.

## 13. Qualification strategy

The system is qualified at progressively wider boundaries:

1. **Mathematical/numeric verification:** interpolation response, scaling,
   quantization, DEM behavior and correction-model accuracy.
2. **RTL subsystem verification:** framing, rate configuration, memory
   transport, coefficient activation, numeric processing, diagnostics and faults.
3. **Complete digital-system verification:** source-to-converter sample
   conservation, real clock ratios, feedback deadlines, state transitions
   and reset recovery.
4. **FPGA implementation qualification:** resource fit, timing, CDC/reset
   checks, I/O constraints and electrical timing assumptions.
5. **Circuit and planned-layout review:** power/reference loops, compliance,
   output protection, thermal paths, interconnects and manufacturability.
6. **Physical qualification after fabrication:** startup and fault behavior,
   manual measurements, calibration, then N1/D1/D2/D3/L1 across the agreed
   operating matrix.

Tests at one boundary are evidence for that boundary. A numeric model
does not establish board performance, and a valid schematic netlist does
not establish the complete source-to-output behavior.

A handoff for independent review should contain this specification, the
control protocol, the chosen component realization, the FPGA source/build
configuration, calibration/fixture definitions, physical constraints and
the relevant verification records. The companion
[Implementation Review and Gap Analysis](IMPLEMENTATION_REVIEW.md) records
the current evidence, findings and closure requests separately.

### 13.1 Design parameters still to be finalized

These are the remaining system/physical choices that the detailed design
must resolve without changing the ownership and signal-flow principles above:

| Area | Required outcome |
|---|---|
| AP/base assembly | Processor, source/UI interfaces, buffering/software architecture and supply-return implementation |
| Filter library | Per-rate responses, active tap counts, normalization, latency and final qualified FPGA geometry |
| Calibration system | Fixture, identification/temperature datasets, versioning and manufacturing/service workflow |
| Protection/readiness | Qualified warm-up criteria, physical fault timing, output-DC policy and recovery/re-arm rules |
| Mechanical/interconnect | Exact mating assemblies, height/clearance tolerances, mounting and thermal interfaces |
| PCB realization | Floorplan, stackup, return structure, timing/matching/capacitance constraints and completed layout |
| Acceptance matrix | Exact loads, temperatures, supply corners, bandwidths, latency, channel matching and crosstalk criteria |

## 14. Component and implementation map

This map identifies the principal realization of the intended functions.
It is an entry point into the detailed design, not a replacement for the
BOM, component drawings or implementation evidence.

| System function | Principal components / source |
|---|---|
| FPGA compute and local infrastructure | Alinx ACVU13P SoM, XCVU13P; [top-level RTL](../Xilinx/vu13p_dac_top.sv) |
| Stream-mode control and I²S | [stream_rate_controller](../Xilinx/stream_rate_controller.sv), [i2s_master_ingress](../Xilinx/i2s_master_ingress.sv) |
| DSP chain | [dac_dsp_core](../Xilinx/dac_dsp_core.sv), FIR/halfband modules, [noise_shaper_ef3](../Xilinx/noise_shaper_ef3.sv), [dem_sort](../Xilinx/dem_sort.sv) |
| Predistortion and calibration memory | [dpd_engine](../Xilinx/dpd_engine.sv), [cal_coef_store](../Xilinx/cal_coef_store.sv) |
| Filter transport/storage | Micron MT25QU02G-class carrier NOR, SoM DDR4, [coefficient subsystem](../Xilinx/dac_coef_subsys.sv), flash/boot-loader modules |
| Audio clock source/distribution | Crystek CCHD-957 family; LMK1C1108 fanouts; FPGA MMCM for digital domains |
| DATA translation and reclocking | SN74AXC8T245 family and SN74LVC1G74 per-cell FFs |
| Current cells | THAT300 arrays, DMMT5551 steering pairs and precision tail/base networks |
| Cascode/replica/padding | Si1555DL devices, 2SA1036K replica circuitry, associated bias/servo networks |
| I/V conversion | OPA1612 + BUF634A feedback loops |
| Precision reference | REF7050 with filtering, OPA1656/OPA1612 buffering and channel reference networks |
| Analog/local regulation | LT3045, LT3094, ADP7158, TPS7A2033; TPS3890 supervision where required |
| AP isolation | MAX22445/MAX22444 families for serial/control paths; ISO1640 for I²C |
| Monitoring | TMP117 temperature sensors and two UCD90120A rail monitors |
| Output connection/protection | G6K-2F-Y DC3 relays, ULN2003V12-class driver, NC3MD-H-B XLR connectors |
| Manual tests | [bench_test_controller](../Xilinx/bench_test_controller.sv), [bench_test_stimulus](../Xilinx/bench_test_stimulus.sv), Würth buttons and Kingbright LEDs |

### Supporting documents

- [Implementation review, evidence and gap analysis](IMPLEMENTATION_REVIEW.md)
- [Control/coefficient protocol](coef_format_v2.md)
- [BOM and circuit realization](../bom.md)
- [Current generated KiCad project](../hw/kicad/bfdac_analog.kicad_pro)
- [Schematic generator](../utils/gen_kicad.py) and [analog reference netlist](../hw/ref_netlist.md)
- [FPGA pin/timing constraints](../Xilinx/vu13p_dac_top.xdc)
- [Decision and verification history](../progress.md)

The BOM and progress notes retain historical material. The current system
design is the coherent intent described here; the review companion identifies
where the implementation or supporting evidence still needs reconciliation.
