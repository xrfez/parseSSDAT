## The types of a decoded `.dat` signature file: the three channels, the trigger
## time, the two positions, the shot, and the errors the decoder raises.

type
  DatChannel* = enum
    ## The three recorded channels, in file order. The second and third are the
    ## controller's reaction-mass and baseplate force channels (mass-weighted
    ## accelerations), raw counts. The external converter that some sites use labels
    ## the two the other way round.
    dcReference = "reference"
    dcMass = "reaction-mass force"
    dcBaseplate = "baseplate force"

  DatFormatError* = object of CatchableError
    ## Not a `.dat` signature file, or one whose bytes break the format. The
    ## message is plain words that name the block and what is wrong.
    offset*: int64 = -1 ## byte offset of the problem in the file; -1 if none

  DatIncompleteError* = object of DatFormatError
    ## The file ends (or turns to zeros) before the blocks its header announces,
    ## or holds no samples: a recording that was stopped or a copy cut short.

  DatWriteError* = object of CatchableError
    ## A shot or an option that the SEG-Y or SEG-D writer cannot take: a number
    ## the format cannot hold (a source index above 255 in SEG-D, a file number
    ## beyond SEG-D's), a weight that is not positive, an interval that is not a whole
    ## number of microseconds for SEG-D, an existing output file. The message
    ## names the value. Problems with the file system are `IOError`.

  DatTime* = object
    ## A time of day, UTC.
    year*, month*, day*, hour*, minute*, second*: int
    nanosecond*: int

  DatGga* = object
    ## The GGA sentence captured in the header text.
    valid*: bool                         ## false when there is none or it does not parse
    latitudeDeg*, longitudeDeg*: float64 ## signed decimal degrees
    altitudeM*: float64                  ## above the geoid (GGA field 9); 0 when the field is empty
    geoidSeparationM*: float64           ## GGA field 11; 0 when the field is empty
    fixQuality*, satellites*: int
    hdop*: float64

  DatFix* = object
    ## The binary position of the position record: a different fix from the
    ## GGA sentence's.
    latitudeDeg*, longitudeDeg*: float64 ## signed decimal degrees; NaN when absent
    heightDm*: int ## as stored; its meaning is not certain
    fixQuality*, satellites*: int
    hdop*: float64

  DatLimit* = enum
    ## A limit letter of the controller's report that a sweep tripped (bits 0 to 4 of
    ## the QC record's fourth status byte). Only the report's letters are known, not
    ## what each limit is.
    dlT = "T"
    dlM = "M"
    dlV = "V"
    dlF = "F"
    dlR = "R"

  DatQc* = object
    ## The controller's 240-byte QC record, embedded in the trailer: the fields
    ## that are decoded, and the record's raw bytes. Values are as stored, not
    ## checked. A field marked probable is matched only in part or by a weak test;
    ## "unknown" means what the number measures is not known.
    valid*: bool ## false when the file has no QC record (a stopped recording)
    raw*: seq[byte] ## the 240 bytes; empty when not `valid`
    crew*: int
    vibratorId*: int ## the vibrator ID an operator knows the vibrator by
    sweepNumber*: int ## the controller's sweep-table entry (16 for a pulse record)
    sweepId*: int64
    sweepChecksum*, paramChecksum*: uint16
    trigger*: DatTime ## year 2000 + the two stored digits; nanosecond -1 if not below a second
    phaseMaxDeg*: float64 ## the maximum phase error, byte 16 / 8 degrees: probable
    forceMaxPct*, forceMinPct*, forceAvgPct*: int
      ## The fundamental force over the valid windows of the sweep, as % of the hold-down
      ## weight: maximum, minimum, average. The minimum and the average are matched
      ## in part only (probable).
    thdMaxPct*, thdAvgPct*: int
      ## Distortion (THD) maximum and average, %. How the controller defines
      ## distortion is unknown; the average is not reliable in the first firmware.
    limits*: set[DatLimit] ## limits that tripped; what each limit is, is unknown
    statusFlags*: array[4, uint8] ## bytes 28 to 31, raw
    correlationMagnitude*: int ## bytes 36-37, proportional to the zero-lag correlation: probable
    correlation*: seq[int8]
      ## The controller's cross-correlation of the reference with the ground force:
      ## 128 values at 2 ms lags from -128 to +126 ms, lag 0 at index 64, scaled so
      ## that lag 0 is -126 (probable). Empty when the record does not store it.
    heightCm*: int64 ## above the ellipsoid, a fix near the GGA altitude plus geoid separation
    satellites*: int
    pdop*, hdop*, vdop*: float64
    correctionAgeS*: int
    stiffness*, viscosity*: tuple[max, min, avg: int]
      ## Over the sweep. The stiffness maximum saturates at 255.
    targetForceLbf*: int ## the drive level times the hold-down weight, in pounds-force
    shotId*, sourceLine*, sourceStation*: int64 ## 0: not given

  DatRawRecord* = object
    ## One record of the file that is not sample data, as stored.
    kind*: uint8      ## 0x80 (header), 0x87 (position) or 0x84 (trailer)
    offset*: int64    ## of its block in the file
    bytes*: seq[byte] ## the whole 512-byte block

  DatInfo* = object of RootObj
    ## Everything about a `.dat` file but its samples: what a file list shows.
    ## `readDatInfo` fills it from three blocks of the file.
    controllerSerial*: int64
      ## The controller's serial number: the record header's 32-bit number, the same in
      ## every block. Header bytes 32 and 33 hold it again as its remainder and quotient
      ## by 100, which agrees in every file seen (an observation, not a check).
    fileNumber*: int64
    firmware*: tuple[major, minor: int]
    trigger*: DatTime ## UTC time of sample 0
    sampleIntervalUs*: float64 = 1000
      ## The interval of the samples. The file does not state it: this is what the
      ## caller said (1000 by default).
    blocks*: int ## the blocks the header announces
    declaredSamples*: int ## per channel, from the header record
    samples*: int
      ## Samples per channel present. From `readDatInfo` of an incomplete file: at
      ## most that many (counted from the file's size).
    complete*: bool ## every announced block is present
    incompleteWhy*: string ## plain words when not complete
    headerText*: string ## the GNSS text of the header record
    gga*: DatGga
    fix*: DatFix
    sourceLine*, sourceStation*, shotId*, sourceIndex*, sweepId*: int64 ## 0: not given
    trailerCounter*: int64 ## trailer bytes 46-49, meaning unknown
    qc*: DatQc

  DatShot* = object of DatInfo
    ## One decoded `.dat` file: its `DatInfo` and the samples, raw counts.
    data*: array[DatChannel, seq[int32]] ## equal lengths
    records*: seq[DatRawRecord]          ## header, position and trailer records, raw

const
  DatBlockBytes* = 512 ## every record of the file takes one block of this size
  MaxDatBytes* = 64 shl 20 ## larger files are refused before reading
