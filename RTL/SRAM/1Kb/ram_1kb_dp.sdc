## SDC for RAM256_1RW1R (256x32)
## Clock period: 10 ns (100 MHz)

create_clock -name CLK -period 10 [get_ports CLK]

set_input_delay  3.0 -clock CLK [get_ports {WE0 EN0 A0 Di0 EN1 A1}]
set_output_delay 3.0 -clock CLK [all_outputs]

set_driving_cell -lib_cell sky130_fd_sc_hd__inv_1 -pin Y [all_inputs]
set_load 0.07 [all_outputs]
