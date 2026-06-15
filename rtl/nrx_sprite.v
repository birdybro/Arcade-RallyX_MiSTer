
module NRX_SPRITE
(
	input					VCLKx4,
	input	 [3:0]		GAME,

	input					HBLK,

	input	 [8:0]		HPOS,
	input	 [8:0]		VPOS,

	output reg [10:0]	SPRAADRS,
	input  [15:0]		SPRADATA,

	output [3:0]		ARAMADRS,
	input	 [7:0]		ARAMDATA,

	output [12:0]		SPCHRADR,
	input	 [7:0]		SPCHRDAT,

	output [7:0]		DROMAD,
	input  [7:0]		DROMDT,

	output reg [8:0]	SPCOL
);

// Hardware family flags
wire is_konami     = ( GAME >= 4'd2 );	// jungler_spritelayout (planes {4,0}, swapped columns)
wire spr_loco      = ( GAME >= 4'd3 );	// locomotn sprites: 7-bit code + combined flip
wire spr_base_zero = ( GAME == 4'd5 );	// Commando scans more sprite slots

reg [1:0] clkcnt;
always @( posedge VCLKx4 ) clkcnt<=clkcnt+1;
wire VCLKx2 = clkcnt[0];
wire VCLK	= clkcnt[1];

wire SIDE = VPOS[0];


reg  [19:0] SPATR0;
reg  [36:0] SPATRS[0:31];
reg	[3:0] WWADR;
reg			bHit;

assign ARAMADRS = SPRAADRS[3:0];


reg	[7:0] WRADR;
reg	[8:0] HPOSW;
reg	[8:0] SPWCL;

wire [36:0] SPA  = SPATRS[{~SIDE,WRADR[7:4]}];

// Column-group order within the 16-wide sprite: Namco uses [byte 8,16,24,0]
// (SH[3:2]=WRADR[3:2]+1); the Konami jungler_spritelayout swaps groups 1<->3
// (SH[3:2]=WRADR[3:2]^1). Pixel order within a group (SH[1:0]) is unchanged.
wire	[3:0] SH	 = is_konami ? { WRADR[3:2]^2'b01, WRADR[1:0] }
                             : ( WRADR[3:0] + 4'h4 );
wire	[3:0] SV	 = SPA[35:32];

// locomotn sprites combine flip into one bit (SPA[1] drives both X and Y);
// Namco/Jungler keep an independent flipx (SPA[0]).
wire	[2:0] SPFY = { 3{SPA[1]} };
wire	[1:0] SPFX = { 1'b0, spr_loco ? SPA[1] : SPA[0] };
wire	[5:0] SPPL = SPA[29:24];

// Sprite code: 6-bit (Namco/Jungler) or 7-bit extended (locomotn-family):
//   code = (spr&0x7c)>>2 + 0x20*(spr&0x01) + (spr&0x80)>>1
wire	[6:0] SPCODE = spr_loco ? { SPA[7], SPA[0], SPA[6:2] } : { 1'b0, SPA[7:2] };

assign SPCHRADR  = { SPCODE, ( SV[3] ^ SPA[1] ), ( SH[3:2] ^ SPFX ), ( SV[2:0] ^ SPFY ) };
wire	[7:0] CHRO = SPCHRDAT;

// Sprite pixel planes: Konami uses {4,0} (reversed vs Namco {0,4}); swap the bits.
wire	[1:0] SPC  = SH[1:0] ^ {2{SPFX[0]}};
wire			SPHI = CHRO[{1'b1, ~SPC}];	// plane bit at ROM bits 4-7
wire			SPLO = CHRO[{1'b0, ~SPC}];	// plane bit at ROM bits 0-3


wire	[8:0] YM = ( SPRADATA[15:8] + 8'h10 ) + (VPOS[7:0]+1);

// Radar-dot gfx code: Namco ~radarattr[3:1], Konami ~radarattr[2:0].
assign DROMAD = { 1'b0, ( is_konami ? ~SPA[18:16] : ~SPA[19:17] ), SPA[33:32], WRADR[3:2] };


always @ ( posedge VCLKx2 ) begin

	// in H-BLANK
	if ( HBLK ) begin

		// Sprite V-hit check & list-up
		if ( SPRAADRS < 10'h20 ) begin
			if ( SPRAADRS[0] ) begin
				if ( bHit ) begin
					SPATRS[{SIDE,WWADR}] <= { 1'b1, SPATR0[3:0], SPRADATA, SPATR0[19:4] };
					WWADR <= WWADR+1;
				end
			end
			else begin
				if ( YM[7:4] == 4'b1111 ) begin
					bHit	<= 1;
					SPATR0 <= { SPRADATA, YM[3:0] };
				end
				else bHit <= 0;
			end
			SPRAADRS <= ( SPRAADRS == 10'h1F ) ? 10'h34 : (SPRAADRS+1);
		end
		// Rader-dot V-hit check & list-up
		else begin
			if ( SPRAADRS < 10'h40 ) begin
				if ( YM[7:2] == 6'b111111 ) begin
					SPATRS[{SIDE,WWADR}] <= { 1'b0, 2'b00, YM[1:0], 8'h0, ARAMDATA, SPRADATA };
					WWADR <= WWADR+1;
				end
				SPRAADRS <= SPRAADRS+1;
			end
			else SPATRS[{SIDE,WWADR}] <= 0;
		end

		if ( SPA ) begin
			// Rend Sprite
			if ( SPA[36] ) begin
				HPOSW <= ( WRADR[3:0] ) ? (HPOSW+1) : { SPA[31], SPA[23:16] };
				SPWCL <= is_konami ? { 1'b0, SPPL, SPLO, SPHI }
				                   : { 1'b0, SPPL, SPHI, SPLO };
				WRADR <= WRADR+1;
			end
			// Rend Rader-dot
			else begin
				// Radar-dot X high bit: Namco ~radarattr[0], Konami ~radarattr[3].
				HPOSW <= ( WRADR[3:0] ) ? (HPOSW+1) : {( is_konami ? ~SPA[19] : ~SPA[16] ),SPA[7:0]};
				SPWCL <= ( DROMDT[1:0] != 2'b11 ) ? { 1'b1, 6'b000100, DROMDT[1:0] } : 0;
				WRADR <= WRADR+4;
			end
		end
		else SPWCL <= 0;

	end

	// in H-DISP
	else begin
		SPRAADRS <= spr_base_zero ? 10'h00 : 10'h14;	// Commando scans more sprites
		WWADR <= 0;
		WRADR <= 0;
		SPWCL <= 0;
	end

end


reg  [9:0] radr0=0,radr1=1;
wire [8:0] SPCOLi;

LINEBUF1024_9 linedbuf(VCLKx2,{SIDE,HPOS},(radr0==radr1),SPCOLi, ~VCLKx2,{~SIDE,HPOSW},(SPWCL[0]|SPWCL[1]),SPWCL);

always @(posedge VCLK) radr0 <= {SIDE,HPOS};
always @(negedge VCLK) begin 
	if (radr0!=radr1) SPCOL <= SPCOLi;
	radr1 <= radr0;
end

endmodule
