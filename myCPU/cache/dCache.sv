`include "dCache.vh"

typedef logic [31:0] d_int;
/* SRAM */
module dCache #(
    parameter TAG_WIDTH    = `CACHE_T,
              INDEX_WIDTH  = `CACHE_S,
              SET_NUM      = `SET_NUM,
              OFFSET_WIDTH = `CACHE_B,
              OFFSET_SIZE  = 2 ** (`CACHE_B - 2),
              LINE_NUM     = `CACHE_E
)(
    /* CPU */
    input  logic           clk, reset, 
    input  logic           cpu_req, // whether the cache module is asked 
    input  logic           wr, // whether is a write request
    input  logic [1 : 0]   size, // the byte size of the request   0:1byte 1:2bytes 2:4bytes
    input  logic [31 : 0]  data_addr, // the request address
    input  logic [31 : 0]  wdata, // the data need to be written
    output logic           cpu_addr_ok,
    output logic           cpu_data_ok, // whether the data is transported
    output logic [31 : 0]  data_rdata, // the data need to be read 
    
    /* Memory */
    output logic           mem_req,
    output logic           mem_wen,
    output logic [31 : 0]  mem_addr,
    output logic [31 : 0]  mem_wdata,
    input  logic [31 : 0]  mem_rdata,
    input  logic           mem_addr_ok,
    input  logic           mem_data_ok
);
    
    logic [TAG_WIDTH - 1 : 0] data_addr_tag, data_addr_tag_0;
    logic [INDEX_WIDTH - 1 : 0] data_addr_index, data_addr_index_0;
    logic [OFFSET_WIDTH - 3 : 0] data_addr_offset, data_addr_offset_0;
    logic [OFFSET_WIDTH - 3 : 0] data_block_offset, addr_block_offset;
    logic [1 : 0] data_addr_bit, data_addr_bit_0;
    logic linew_en, new_valid, offset_sel, strategy_en;
    logic [OFFSET_WIDTH - 3 : 0] block_offset;
    logic [LINE_NUM - 1 : 0] ram_data[31 : 0];
    logic [31 : 0] replaceID;
    logic [31 : 0] data_rdata_0;
    logic [1 : 0] state;
    logic [1 : 0] wr_size;
    logic hit, hit_1, cpu_req_1;
    logic set_dcache_valid, set_dcache_dirty;
    
    assign data_addr_tag_0 = data_addr[31 : INDEX_WIDTH + OFFSET_WIDTH];
    assign data_addr_index_0 = data_addr[INDEX_WIDTH + OFFSET_WIDTH - 1 : OFFSET_WIDTH];
    assign data_addr_offset_0 = data_addr[OFFSET_WIDTH - 1 : 2];
    assign data_addr_bit_0 = data_addr[1 : 0];
    assign data_addr_tag = data_addr_tag_0;
    assign data_addr_index = data_addr_index_0;
    assign data_addr_offset = data_addr_offset_0;
    assign data_addr_bit = data_addr_bit_0;
    

    logic [TAG_WIDTH - 1 : 0] dcache_line_tag[LINE_NUM - 1 : 0];
    logic [OFFSET_SIZE * 32 - 1 : 0] dcache_line_data[LINE_NUM - 1 : 0];
    logic [LINE_NUM - 1 : 0] dcache_line_valid;
    logic [LINE_NUM - 1 : 0] dcache_line_dirty;
    logic [LINE_NUM - 1 : 0] way_selector;
    logic [OFFSET_SIZE * 32 - 1 : 0] line_data;
    logic line_data_ok;
    logic [31:0] hit_line_num;
    logic [LINE_NUM - 1 : 0] dcache_line_wen;
    
    // access cache
    // the data in the same cacheline was organized in the same ram
    // the `data_addr_index` can be used to locate the accurate data position in both RAM 
    genvar i;
    generate
        for (i = 0; i < LINE_NUM; i = i + 1) begin:AccessCache
        
        assign dcache_line_wen[i] = linew_en && (((i == replaceID) && (state == 2'b01)) || (way_selector[i] && state == 2'b00));
    
        dCache_Ram #(TAG_WIDTH + 2, OFFSET_SIZE)
                    dcache_info_ram(clk, reset, data_addr_index, data_addr_bit, data_addr_offset, 2'b11,
                                    {set_dcache_valid, set_dcache_dirty, data_addr_tag}, 
                                    {dcache_line_valid[i], dcache_line_dirty[i], dcache_line_tag[i]}, 
                                    dcache_line_wen[i], (i == replaceID) & line_data_ok);
                        
        dCache_Ram #(OFFSET_SIZE * 32, OFFSET_SIZE) 
                    dcache_data_ram(clk, reset, data_addr_index, data_addr_bit, data_addr_offset, wr_size,
                                    line_data, 
                                    dcache_line_data[i], 
                                    dcache_line_wen[i], (i == replaceID) & line_data_ok);
        
        always_comb
            if (dcache_line_tag[i] == data_addr_tag) way_selector[i] <= 1;
            else way_selector[i] <= 0;
        end
    endgenerate
    
    // getting results
    always_comb
        begin
            hit_line_num = 0;
            for (int i = 0; i < LINE_NUM; i = i + 1)
                hit_line_num |= (way_selector[i] == 1) ? d_int'(i) : 0;
        end 
        
    always_comb
        case (hit)
            1'b1 : data_rdata_0 <= dcache_line_data[hit_line_num][data_addr_offset * 32 +: 32];
            default : data_rdata_0 <= dcache_line_data[replaceID][data_addr_offset * 32 +: 32];
        endcase
        
    assign hit = (state == 2'b00) && |way_selector;
        
    dCache_Replacement dcache_replacement(clk, reset, cpu_req, hit, state, replaceID);
        
    dCache_Controller dcache_ctrl(clk, reset, cpu_req, wr, hit, dcache_line_dirty[replaceID], 
                                  data_addr_bit, data_addr_offset, addr_block_offset, data_block_offset, 
                                  linew_en, set_dcache_valid, set_dcache_dirty, mem_wen, offset_sel, state, //cpu_data_ok,
                                  mem_req, mem_data_ok, mem_addr_ok, mem_rdata, wdata, line_data, line_data_ok, size, wr_size);
    
    assign cpu_addr_ok = cpu_req & hit;
        
    flop #(2) dcache_flop(clk, reset, 0, {hit  , cpu_req  },
                                         {hit_1, cpu_req_1});

    flop #(32) dcache_flop_2(clk, reset, 0, data_rdata_0, data_rdata);
    assign cpu_data_ok = hit_1 & cpu_req_1;
            
    mux2 #(32) maddr_mux({data_addr[31 : OFFSET_WIDTH], addr_block_offset, 2'b00},  
                         {dcache_line_tag[replaceID], data_addr_index, addr_block_offset, 2'b00}, 
                         mem_wen, mem_addr);

    assign mem_wdata = dcache_line_data[replaceID][data_block_offset * 32 +: 32];
    
endmodule