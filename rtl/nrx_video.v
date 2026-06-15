/**************************************************************
	FPGA New Rally-X (Video Part)
***************************************************************/
module NRX_VIDEO
(
	input				 VCLKx4,		// 24.976MHz

	input  [3:0]		GAME,			// Game select (see fpga_nrx.v)

	input  [8:0]		HPOSi,
	input  [8:0]		VPOSi,
	output				PCLK,
	output reg [7:0]	POUT,

	input					CPUCLK,
	input	 [15:0]		CPUADDR,
	input	 [7:0]		CPUDI,
	output [7:0]		CPUDO,
	input					CPUME,
	input					CPUWE,
	output				CPUDT,

	input					ROMCL,
	input  [15:0]		ROMAD,
	input  [7:0]		ROMDT,
	input					ROMEN,

	input	 [15:0]	hs_address,
	input	 [7:0]	hs_data_in,
	output [7:0]	hs_data_out,
	input				hs_write,
	input				hs_access
);

wire [8:0] HPOS = HPOSi+2;
wire [8:0] VPOS = VPOSi+(HPOSi>=504);

//-----------------------------------------
//  Hardware family flags
//-----------------------------------------
wire is_konami     = ( GAME >= 4'd2 );	// Jungler/Tactician/Loco-Motion/Commando
wire tile_loco     = ( GAME >= 4'd3 );	// Tactician/Loco-Motion/Commando (locomotn tile_info, 0x2000 gfx1)
wire tile_prio_off = ( GAME == 4'd2 );	// Jungler disables tile priority

//-----------------------------------------
//  Clock generators
//-----------------------------------------
reg VCLKx2;
always @( posedge VCLKx4 ) begin
	VCLKx2 <= ~VCLKx2;
end

reg VCLK;
always @( posedge VCLKx2 ) begin
	VCLK   <= ~VCLK;
end

//-----------------------------------------
//  BG scroll registers
//-----------------------------------------
reg [7:0] BGHSCR;
reg [7:0] BGVSCR;

always @ ( posedge CPUCLK ) begin
	if ( ( CPUADDR == 16'hA130 ) & CPUME & CPUWE ) begin
		// Rally-X applies set_scrolldx(3,3); the Konami games do not.
		BGHSCR <= is_konami ? CPUDI : (CPUDI-3);
	end
	if ( ( CPUADDR == 16'hA140 ) & CPUME & CPUWE ) begin
		BGVSCR <= CPUDI;
	end
end


//-----------------------------------------
//  HV
//-----------------------------------------
wire [8:0] BGHPOS = HPOS + { 1'b0, BGHSCR };
wire [8:0] BGVPOS = VPOS + { 1'b0, BGVSCR };

wire oHB = ( HPOS > 288 ) ? 1 : 0;
wire oVB = ( VPOS > 224 ) ? 1 : 0;


//----------------------------------------
//  VideoRAM Scanner
//----------------------------------------
wire				BF	= ( HPOS >= 224 );
wire	[8:0]		HP = ( BF ? HPOS : BGHPOS );
wire	[8:0]		VP = ( BF ? VPOS : BGVPOS ) + 9'd16;

wire	[10:0]	SPRAADRS;
wire	[3:0]		ARAMADRS;

reg	[10:0]	VRAMADRS;
always @ ( HPOS ) begin
	VRAMADRS <= oHB ? 
		SPRAADRS :
		BF ? { 1'b0, VP[7:3], 2'b00, HP[5:3] } : { 1'b1, VP[7:3], HP[7:3] };
end

wire	[7:0]		CHRC;
wire	[7:0]		ATTR;
wire	[7:0]		ARDT;

wire	[7:0]		V0DO, V1DO;

wire				CEV0	= ( ( CPUADDR[15:12] == 4'b1000 ) & (~CPUADDR[11]) ) & CPUME;
wire				CEV1	= ( ( CPUADDR[15:12] == 4'b1000 ) &   CPUADDR[11]  ) & CPUME;
// Radar/bullet attribute latch: Namco $A000-$A00F, Konami $A000-$A0FF (mirror 0x00f0)
wire				CEAT  = ( is_konami ? ( CPUADDR[15:8] == 8'hA0 )
                                    : ( CPUADDR[15:4] == 12'b1010_0000_0000 ) ) & CPUME;

wire	[7:0]		DTV0	= CEV0 ? V0DO : 8'h00;
wire	[7:0]		DTV1	= CEV1 ? V1DO : 8'h00;

assign			CPUDO = DTV0 | DTV1;
assign			CPUDT = ( ~CPUWE ) & ( CEV0 | CEV1 );

// Hiscore mux
wire 			wram0_clk = hs_access ? ROMCL : CPUCLK;
wire [10:0]	wram0_addr = hs_access ? hs_address[10:0] : CPUADDR[10:0];
wire 			wram0_we = hs_access ? hs_write : (CPUWE & CEV0);
wire [7:0]	wram0_di = hs_access ? hs_data_in : CPUDI;
wire [7:0]	wram0_do;

assign hs_data_out = hs_access ? wram0_do : 8'h00;
assign V0DO = hs_access ? 8'h00 : wram0_do;

GDPRAM #(11,8) vram0( VCLKx4, VRAMADRS, CHRC, wram0_clk, wram0_addr, wram0_we, wram0_di, wram0_do);  
GDPRAM #(11,8)	vram1( VCLKx4, VRAMADRS, ATTR, CPUCLK, CPUADDR[10:0], ( CPUWE & CEV1 ), CPUDI, V1DO );  
GDPRAM #(4,8)	aram0( VCLKx4, ARAMADRS, ARDT, CPUCLK, CPUADDR[3:0],  ( CPUWE & CEAT ), CPUDI );

// Tile priority/category bit (ATTR[5]); Jungler disables tile priority.
wire				BGF = tile_prio_off ? 1'b0 : ATTR[5];


//----------------------------------------
//  BG/Sprite chip data reader
//----------------------------------------
// Flip: Namco/Jungler use independent flipx=ATTR[6]; locomotn-family combine
// flip into ATTR[7] (drives both X and Y). flipy is ATTR[7] in all cases.
wire				BGFX = tile_loco ? ATTR[7] : ATTR[6];
wire	[2:0]		BGFY = { ATTR[7], ATTR[7], ATTR[7] };

// Tile code: 8-bit (Namco/Jungler) or 9-bit extended (locomotn-family, 0x2000 gfx1):
//   code = (code & 0x7f) + 2*(attr & 0x40) + 2*(code & 0x80)
wire	[8:0]		TCODE = tile_loco ? { CHRC[7], ATTR[6], CHRC[6:0] } : { 1'b0, CHRC };

wire	[11:0]	SPCHRADR;
wire	[12:0]	CHRA = oHB ? { 1'b0, SPCHRADR } : { TCODE, ( HP[2] ^ BGFX ), ( VP[2:0] ^ BGFY ) };

wire	[7:0]		CHRO;
// 8K char/sprite ROM (locomotn-family); Namco/Jungler use the lower 4K.
DLROM #(13,8)  chrrom(VCLKx4,CHRA,CHRO, ROMCL,ROMAD,ROMDT,
	ROMEN & ( is_konami ? ( ROMAD[15:13] == 3'b100 ) : ( ROMAD[15:12] == 4'h4 ) ));


//----------------------------------------
//  Rader-dot chip ROM
//----------------------------------------
wire  [7:0] 	DROMAD;
wire  [7:0] 	DROMDT;
DLROM #(8,8)	dotrom(VCLKx4,DROMAD,DROMDT, ROMCL,ROMAD,ROMDT,
	ROMEN & ( is_konami ? ( ROMAD[15:8]==8'hA0 ) : ( ROMAD[15:8]==8'h50 ) ));


//----------------------------------------
//  BG/FG scanline generator
//----------------------------------------
wire [5:0] BGPL = ATTR[5:0];
reg  [7:0] BGCOL;

// Konami games use char planes {4,0} (reversed vs Namco {0,4}) -> swap the two
// color bits. Pixel/column order within the tile is identical for both layouts.
wire [1:0] BGTC = HP[1:0]^{2{BGFX}};
wire       BGLO = CHRO[{1'b0,BGTC}];	// plane bit at ROM bits 0-3
wire       BGHI = CHRO[{1'b1,BGTC}];	// plane bit at ROM bits 4-7

always @ ( posedge VCLK ) begin
	BGCOL <= is_konami ? { BGPL, BGLO, BGHI } : { BGPL, BGHI, BGLO };
end


//----------------------------------------
//  Sprite Engine
//----------------------------------------
wire [8:0] SPCOL;
NRX_SPRITE speng( VCLKx4, oHB, HPOS, VPOS, SPRAADRS, { ATTR, CHRC }, ARAMADRS, ARDT, SPCHRADR, CHRO, DROMAD, DROMDT, SPCOL );


//----------------------------------------
//  Color mixer
//----------------------------------------
wire bBGOPAQUE = ( ( BF | BGF ) & (~SPCOL[8]) );
wire bSPTRANSP = ( SPCOL[1:0] == 2'b00 );

wire	[7:0]		OUTCOL = ( bBGOPAQUE | bSPTRANSP ) ? BGCOL : SPCOL[7:0];
wire	[3:0]		CLUT;
DLROM #(8,4)	colorlt(~VCLKx4,OUTCOL,CLUT, ROMCL,ROMAD,ROMDT,
	ROMEN & ( is_konami ? ( ROMAD[15:8]==8'hB1 ) : ( ROMAD[15:8]==8'h52 ) ));

wire	[4:0]		PALA = SPCOL[8] ? SPCOL[4:0] : { 1'b0, CLUT };
wire	[7:0]		PALO;
DLROM #(5,8)	palette(VCLKx4,PALA,PALO,  ROMCL,ROMAD,ROMDT,
	ROMEN & ( is_konami ? ( ROMAD[15:5]=={8'hB0,3'b000} ) : ( ROMAD[15:5]=={8'h53,3'b000} ) ));


//----------------------------------------
//  Color output
//----------------------------------------
always @ ( posedge PCLK ) POUT <= PALO;
assign PCLK = VCLK;


endmodule
