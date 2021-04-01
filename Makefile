TOOLPATH = /usr/aarch64-linux-gnu/bin
OBJS = raytrace.o main.o

%.o : %.s
	aarch64-linux-gnu-as -g $< -o $@

%.o : %.S
	aarch64-linux-gnu-gcc -c $< -o $@

raytrace: $(OBJS)
	aarch64-linux-gnu-ld -o raytrace $(OBJS)

clean:
	rm raytrace ; rm *.o

run: raytrace
	qemu-aarch64 ./raytrace
